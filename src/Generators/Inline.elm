module Generators.Inline exposing (..)

import CodeGen.Shared as Shared exposing (Context, endoAnn, intlAnn)
import CodeGen.Utils
import Dict
import Dict.NonEmpty
import Elm.CodeGen as CG
import Generators.Names as Names exposing (Names)
import Intl exposing (Intl)
import List.Extra
import List.NonEmpty
import Set
import State exposing (NonEmptyState)
import String.Extra
import Types.ArgValue as ArgValue
import Types.Features as Features
import Types.InterpolationKind as InterpolationKind
import Types.Segment as Segment exposing (TKey, TSegment, TValue)
import Types.Translation exposing (Translation)
import Types.UniqueName as Unique
import Util


type alias WithCtx ctx =
    { ctx
        | names : Names
        , intl : Intl
        , state : NonEmptyState ()
        , file : CG.File
        , i18nArgLast : Bool
    }


type alias WithAccessors ctx =
    { ctx
        | lookupAccessor :
            String
            -> String -- the exposed accessor function
        , lookupAccessorProxy :
            String
            -> String -- the matching key in the inline record
    }


type alias WithI18nProxy ctx =
    { ctx | i18nProxyName : String }


toFileUnique : Unique.UniqueNameContext (WithCtx ctx) -> CG.File
toFileUnique =
    let
        addAccessorsToContext : ( WithCtx ctx, String -> String ) -> (String -> String) -> WithAccessors (WithCtx {})
        addAccessorsToContext ( ctx, lookupAccessor ) lookupAccessorProxy =
            { names = ctx.names
            , intl = ctx.intl
            , state = ctx.state
            , file = ctx.file
            , i18nArgLast = ctx.i18nArgLast
            , lookupAccessor = lookupAccessor
            , lookupAccessorProxy = lookupAccessorProxy
            }

        getKeySet ctx =
            State.allTranslationKeys ctx.state |> Set.fromList
    in
    Unique.combineAndThen getKeySet (\_ -> Tuple.pair)
        >> Unique.combineAndThen (Tuple.first >> getKeySet) (\_ -> addAccessorsToContext)
        >> addInitDeclaration
        >> addLoadLanguageDeclaration
        >> addI18nTypeDeclarations
        >> addAccessorDeclarations
        >> addI18nInstances
        >> Shared.addLanguageRelatedDeclsUnique
        >> Unique.unwrap
        >> .file
        >> Shared.finishFile


addInitDeclaration : Unique.UniqueNameContext (WithCtx ctx) -> Unique.UniqueNameContext (WithCtx ctx)
addInitDeclaration =
    Unique.scoped <|
        Unique.andThen2 "lang" "intl" <|
            \_ ctx langName intlName ->
                let
                    langToI18nAnn =
                        CG.funAnn (CG.typed ctx.names.languageTypeName []) (CG.typed ctx.names.i18nTypeName [])

                    initBody exprFromLang =
                        CG.caseExpr (CG.val langName)
                            (State.getLanguages ctx.state
                                |> List.map
                                    (\lang ->
                                        ( CG.namedPattern (String.Extra.classify lang) []
                                        , exprFromLang lang
                                        )
                                    )
                            )

                    initDecl : CG.Declaration
                    initDecl =
                        if State.inferFeatures ctx.state |> Features.needsIntl then
                            CG.funDecl (Just (CG.emptyDocComment |> CG.markdown "Initialize an i18n instance based on a language and access to the Intl API"))
                                (Just <| CG.funAnn intlAnn langToI18nAnn)
                                ctx.names.initFunName
                                [ CG.varPattern intlName, CG.varPattern langName ]
                                (initBody <| \lang -> CG.tuple [ CG.val lang, CG.val intlName ])

                        else
                            CG.funDecl (Just (CG.emptyDocComment |> CG.markdown "Initialize an i18n instance based on a language"))
                                (Just langToI18nAnn)
                                ctx.names.initFunName
                                [ CG.varPattern langName ]
                                (initBody <| \lang -> CG.val lang)
                in
                { ctx | file = ctx.file |> Shared.addDeclaration initDecl |> Shared.addExposing (CG.funExpose ctx.names.initFunName) }


addLoadLanguageDeclaration : Unique.UniqueNameContext (WithCtx ctx) -> Unique.UniqueNameContext (WithCtx ctx)
addLoadLanguageDeclaration =
    Unique.scoped <|
        Unique.andThen3 "load" "lang" "intl" <|
            \_ ctx loadName langName intlName ->
                let
                    loadLanguageAnn =
                        Just <| CG.funAnn (CG.typed ctx.names.languageTypeName []) (endoAnn <| CG.typed ctx.names.i18nTypeName [])

                    loadLanguageDecl =
                        if State.inferFeatures ctx.state |> Features.needsIntl then
                            CG.funDecl (Just (CG.emptyDocComment |> CG.markdown "Switch to another i18n instance based on a language"))
                                loadLanguageAnn
                                loadName
                                [ CG.varPattern langName, CG.tuplePattern [ CG.allPattern, CG.varPattern intlName ] ]
                                (CG.apply [ CG.fun ctx.names.initFunName, CG.val intlName, CG.val langName ])

                        else
                            CG.funDecl (Just (CG.emptyDocComment |> CG.markdown "Switch to another i18n instance based on a language"))
                                loadLanguageAnn
                                loadName
                                [ CG.varPattern langName, CG.allPattern ]
                                (CG.apply [ CG.fun ctx.names.initFunName, CG.val langName ])
                in
                { ctx | file = ctx.file |> Shared.addDeclaration loadLanguageDecl |> Shared.addExposing (CG.funExpose loadName) }


addI18nTypeDeclarations : Unique.UniqueNameContext (WithAccessors (WithCtx ctx)) -> Unique.UniqueNameContext (WithI18nProxy (WithAccessors (WithCtx {})))
addI18nTypeDeclarations unCtx =
    Unique.andThen (Unique.unwrap unCtx).names.i18nTypeName
        (\_ ctx wrappedI18nTypeName ->
            let
                addIntlIfNeeded key =
                    if State.isIntlNeededForKey key ctx.state then
                        CG.funAnn intlAnn

                    else
                        identity

                interpolationMap =
                    State.interpolationMap <| State.collectiveTranslationSet ctx.state

                i18nTypeDecls =
                    if State.inferFeatures ctx.state |> Features.needsIntl then
                        [ CG.aliasDecl Nothing ctx.names.i18nTypeName [] (CG.tupleAnn [ CG.typed wrappedI18nTypeName [], intlAnn ])
                        , CG.aliasDecl Nothing
                            wrappedI18nTypeName
                            []
                            (CG.recordAnn <|
                                List.map (\k -> ( ctx.lookupAccessorProxy k, addIntlIfNeeded k <| translationToRecordTypeAnn ctx.state k )) (Dict.keys interpolationMap)
                            )
                        ]

                    else
                        [ CG.aliasDecl Nothing
                            ctx.names.i18nTypeName
                            []
                            (CG.recordAnn <|
                                List.map (\k -> ( ctx.lookupAccessorProxy k, translationToRecordTypeAnn ctx.state k )) (Dict.keys interpolationMap)
                            )
                        ]
            in
            { file = ctx.file |> Shared.addDeclarations i18nTypeDecls |> Shared.addExposing (CG.closedTypeExpose ctx.names.i18nTypeName)
            , intl = ctx.intl
            , names = ctx.names
            , state = ctx.state
            , i18nArgLast = ctx.i18nArgLast
            , lookupAccessor = ctx.lookupAccessor
            , lookupAccessorProxy = ctx.lookupAccessorProxy
            , i18nProxyName = wrappedI18nTypeName
            }
        )
        unCtx


addAccessorDeclarations : Unique.UniqueNameContext (WithAccessors (WithCtx ctx)) -> Unique.UniqueNameContext (WithAccessors (WithCtx ctx))
addAccessorDeclarations =
    Unique.scoped <|
        Unique.andThen4 "i18n" "intl" "data" "htmlAttrs" <|
            \_ ctx i18nName intlName dataName htmlAttrsName ->
                let
                    interpolationMap =
                        State.interpolationMap <| State.collectiveTranslationSet ctx.state

                    htmlMap =
                        State.getHtmlIds ctx.state

                    accessorDeclForKey : TKey -> CG.Declaration
                    accessorDeclForKey key =
                        let
                            hasPlaceholders =
                                Dict.get key interpolationMap
                                    |> Maybe.map (not << Dict.isEmpty)
                                    |> Maybe.withDefault False

                            hasHtml =
                                Dict.get key htmlMap
                                    |> Maybe.map (not << Set.isEmpty)
                                    |> Maybe.withDefault False

                            i18nPattern =
                                if State.inferFeatures ctx.state |> Features.needsIntl then
                                    CG.tuplePattern [ CG.varPattern i18nName, CG.varPattern intlName ]

                                else
                                    CG.varPattern i18nName

                            patterns =
                                if ctx.i18nArgLast && hasPlaceholders && hasHtml then
                                    [ CG.varPattern dataName, CG.varPattern htmlAttrsName, i18nPattern ]

                                else if ctx.i18nArgLast && hasPlaceholders then
                                    [ CG.varPattern dataName, i18nPattern ]

                                else if ctx.i18nArgLast && hasHtml then
                                    [ CG.varPattern htmlAttrsName, i18nPattern ]

                                else
                                    [ i18nPattern ]

                            declarationWithoutArgs =
                                if State.isIntlNeededForKey key ctx.state then
                                    CG.apply [ CG.access (CG.val i18nName) (ctx.lookupAccessorProxy key), CG.val intlName ]

                                else
                                    CG.access (CG.val i18nName) (ctx.lookupAccessorProxy key)

                            declaration =
                                if ctx.i18nArgLast && hasPlaceholders && hasHtml then
                                    CG.apply [ declarationWithoutArgs, CG.val dataName, CG.val htmlAttrsName ]

                                else if ctx.i18nArgLast && hasPlaceholders then
                                    CG.apply [ declarationWithoutArgs, CG.val dataName ]

                                else if ctx.i18nArgLast && hasHtml then
                                    CG.apply [ declarationWithoutArgs, CG.val htmlAttrsName ]

                                else
                                    declarationWithoutArgs
                        in
                        CG.funDecl Nothing
                            (Just <|
                                (if ctx.i18nArgLast then
                                    CodeGen.Utils.funAnnArgLast

                                 else
                                    CG.funAnn
                                )
                                    (CG.typed ctx.names.i18nTypeName [])
                                    (translationToRecordTypeAnn ctx.state key)
                            )
                            (ctx.lookupAccessor key)
                            patterns
                            declaration

                    accessorDecls =
                        State.allTranslationKeys ctx.state
                            |> List.map accessorDeclForKey

                    exposings =
                        State.allTranslationKeys ctx.state
                            |> List.map (ctx.lookupAccessor >> CG.funExpose)
                in
                { ctx | file = ctx.file |> Shared.addDeclarations accessorDecls |> Shared.addExposings exposings }


addI18nInstances : Unique.UniqueNameContext (WithAccessors (WithCtx ctx)) -> Unique.UniqueNameContext (WithAccessors (WithCtx ctx))
addI18nInstances =
    Unique.andThen4 "data" "intl" "n" "extraAttrs" <|
        \lookup ctx dataName intlName numName extraAttrsName ->
            let
                interpolationMap =
                    State.interpolationMap translationSet

                htmlIdDict =
                    State.getHtmlIds ctx.state

                translationSet =
                    State.collectiveTranslationSet ctx.state

                i18nDeclForLang : String -> Translation () -> CG.Declaration
                i18nDeclForLang lang translation =
                    let
                        typeDecl =
                            if State.inferFeatures ctx.state |> Features.needsIntl then
                                CG.typed (Util.safeName ctx.names.i18nTypeName) []

                            else
                                CG.typed ctx.names.i18nTypeName []
                    in
                    CG.funDecl (Just (CG.emptyDocComment |> CG.markdown ("`I18n` instance containing all values for the language " ++ String.Extra.classify lang)))
                        (Just typeDecl)
                        lang
                        []
                    <|
                        CG.record
                            (List.map
                                (\k ->
                                    ( ctx.lookupAccessorProxy k
                                    , case Dict.get k translation.pairs of
                                        Just v ->
                                            inlineTemplate lang k v

                                        Nothing ->
                                            case translation.fallback of
                                                Just fallbackLang ->
                                                    CG.access (CG.val fallbackLang) (ctx.lookupAccessorProxy k)

                                                Nothing ->
                                                    inlineTemplate lang k ( Segment.Text <| "Missing key: '" ++ k ++ "'", [] )
                                    )
                                )
                             <|
                                List.sort <|
                                    Dict.keys interpolationMap
                            )

                inlineTemplate : String -> TKey -> TValue -> CG.Expression
                inlineTemplate lang key value =
                    let
                        placeholders =
                            Dict.get key interpolationMap |> Maybe.withDefault Dict.empty

                        htmlIds =
                            Dict.get key htmlIdDict |> Maybe.withDefault Set.empty

                        toHtml =
                            Shared.applyWithParensIfNecessary (CG.fqFun [ "Html" ] "text")

                        needsHtmlConversion seg =
                            Set.isEmpty (Segment.htmlIdsForSegment seg) && not (Set.isEmpty htmlIds)

                        specificPlaceholdersForThisLanguage =
                            Segment.interpolationVars value

                        accessParam =
                            if Dict.size placeholders == 1 then
                                CG.val << lookup

                            else
                                CG.access (CG.val dataName)

                        addIntlIfNeeded =
                            if State.isIntlNeededForKey key ctx.state then
                                (::) (CG.varPattern intlName)

                            else
                                identity

                        addHtmlAttrsIfNeeded =
                            case Set.toList htmlIds of
                                [] ->
                                    identity

                                [ single ] ->
                                    (::) (CG.varPattern <| lookup <| single ++ "Attrs")

                                _ ->
                                    (::) (CG.varPattern extraAttrsName)

                        refHtmlAttr id =
                            if Set.size htmlIds > 1 then
                                CG.access (CG.val extraAttrsName) id

                            else
                                CG.val <| lookup <| id ++ "Attrs"

                        matchStatement default otherOptions =
                            (Dict.toList otherOptions
                                |> List.map
                                    (\( tkey, tval ) ->
                                        ( CG.stringPattern tkey
                                        , List.NonEmpty.map associateHtmlKindWithSegment tval
                                            |> concatHtmlKindSegments
                                        )
                                    )
                            )
                                ++ [ ( CG.allPattern
                                     , List.NonEmpty.map associateHtmlKindWithSegment default
                                        |> concatHtmlKindSegments
                                     )
                                   ]

                        associateHtmlKindWithSegment : TSegment -> ( HtmlKind, TSegment )
                        associateHtmlKindWithSegment seg =
                            ( case seg of
                                Segment.Html _ ->
                                    IsHtml

                                Segment.PluralCase _ _ _ _ ->
                                    if Set.isEmpty htmlIds then
                                        NoHtml

                                    else
                                        ContainsHtml

                                Segment.InterpolationCase _ _ _ ->
                                    if Set.isEmpty htmlIds then
                                        NoHtml

                                    else
                                        ContainsHtml

                                _ ->
                                    if needsHtmlConversion seg then
                                        NoHtml

                                    else
                                        ContainsHtml
                            , seg
                            )

                        segmentToExpression : TSegment -> CG.Expression
                        segmentToExpression segm =
                            case segm of
                                Segment.Interpolation var ->
                                    (Dict.get var placeholders |> Maybe.map InterpolationKind.interpolatedValueToString |> Maybe.withDefault identity) (accessParam var)

                                Segment.InterpolationCase var default otherOptions ->
                                    CG.caseExpr (accessParam var)
                                        (matchStatement default otherOptions)

                                Segment.PluralCase var numArgs default otherOptions ->
                                    CG.caseExpr
                                        (CG.pipe
                                            (CG.apply
                                                [ CG.fqFun [ "Intl" ] "formatFloat"
                                                , CG.val intlName
                                                , CG.record
                                                    [ ( "number", accessParam var )
                                                    , ( "language", CG.string lang )
                                                    , ( "args", numArgs |> List.map (\( k, v ) -> CG.tuple [ CG.string k, ArgValue.generateEncoded v ]) |> CG.list )
                                                    ]
                                                ]
                                            )
                                            [ CG.fqFun [ "String" ] "toFloat"
                                            , CG.apply
                                                [ CG.fqFun [ "Maybe" ] "map"
                                                , CG.parens <|
                                                    CG.lambda [ CG.varPattern numName ]
                                                        (CG.apply
                                                            [ CG.fqFun [ "Intl" ] "determinePluralRuleFloat"
                                                            , CG.val intlName
                                                            , CG.record
                                                                [ ( "language", CG.string lang )
                                                                , ( "number", CG.val numName )
                                                                , ( "type_", CG.fqVal [ "Intl" ] "Cardinal" )
                                                                ]
                                                            ]
                                                        )
                                                ]
                                            , CG.apply [ CG.fqFun [ "Maybe" ] "withDefault", CG.fqVal [ "Intl" ] "Other" ]
                                            , CG.fqFun [ "Intl" ] "pluralRuleToString"
                                            ]
                                        )
                                        (matchStatement default otherOptions)

                                Segment.FormatDate var args ->
                                    CG.apply
                                        [ CG.fqFun [ "Intl" ] "formatDateTime"
                                        , CG.val intlName
                                        , CG.record
                                            [ ( "time", accessParam var )
                                            , ( "language", CG.string lang )
                                            , ( "args", args |> List.map (\( k, v ) -> CG.tuple [ CG.string k, ArgValue.generateEncoded v ]) |> CG.list )
                                            ]
                                        ]

                                Segment.FormatNumber var args ->
                                    CG.apply
                                        [ CG.fqFun [ "Intl" ] "formatFloat"
                                        , CG.val intlName
                                        , CG.record
                                            [ ( "number", accessParam var )
                                            , ( "language", CG.string lang )
                                            , ( "args", args |> List.map (\( k, v ) -> CG.tuple [ CG.string k, ArgValue.generateEncoded v ]) |> CG.list )
                                            ]
                                        ]

                                Segment.Text text ->
                                    CG.string text

                                Segment.Html html ->
                                    CG.apply
                                        [ CG.fqFun [ "Html" ] "node"
                                        , CG.string html.tag
                                        , CG.parens <|
                                            Shared.concatenateLists (refHtmlAttr html.id) (generateHtmlAttrs html.attrs)
                                        , generateHtmlContent html.content
                                        ]

                        generateHtmlAttrs attrs =
                            List.map
                                (\( attrKey, attrVal ) ->
                                    CG.apply
                                        [ CG.fqFun [ "Html", "Attributes" ] "attribute"
                                        , CG.string attrKey
                                        , List.NonEmpty.map segmentToExpression attrVal
                                            |> List.NonEmpty.foldl1 Shared.concatenateLists
                                        ]
                                )
                                attrs
                                |> CG.list

                        generateHtmlContent content =
                            List.NonEmpty.map associateHtmlKindWithSegment content
                                |> concatHtmlKindSegments

                        concatHtmlKindSegments segmentsWithHtmlKinds =
                            if Set.isEmpty htmlIds then
                                List.NonEmpty.map (Tuple.second >> segmentToExpression) segmentsWithHtmlKinds |> List.NonEmpty.foldl1 Shared.concatenateLists

                            else
                                -- concat any groups of non-html expressions into lists
                                -- append the lists
                                List.NonEmpty.toList segmentsWithHtmlKinds
                                    |> List.Extra.groupWhile (\( k1, _ ) ( k2, _ ) -> k1 == k2)
                                    |> List.map
                                        (\(( ( htmlKind, _ ), _ ) as group) ->
                                            let
                                                expressions =
                                                    List.NonEmpty.map (Tuple.second >> segmentToExpression) group
                                            in
                                            case htmlKind of
                                                NoHtml ->
                                                    List.NonEmpty.foldl1 Shared.concatenateLists expressions
                                                        |> (if List.NonEmpty.isSingleton group then
                                                                identity

                                                            else
                                                                CG.parens
                                                           )
                                                        |> toHtml
                                                        |> List.NonEmpty.singleton
                                                        |> Tuple.pair htmlKind

                                                _ ->
                                                    ( htmlKind, expressions )
                                        )
                                    |> List.Extra.groupWhile (\( k1, _ ) ( k2, _ ) -> k1 /= ContainsHtml && k2 /= ContainsHtml)
                                    |> List.map
                                        (\(( ( htmlKind, _ ), _ ) as group) ->
                                            case htmlKind of
                                                ContainsHtml ->
                                                    List.NonEmpty.concatMap Tuple.second group
                                                        |> List.NonEmpty.foldl1 Shared.concatenateLists

                                                _ ->
                                                    List.NonEmpty.concatMap Tuple.second group
                                                        |> List.NonEmpty.toList
                                                        |> CG.list
                                        )
                                    |> List.NonEmpty.fromList
                                    -- this is always safe since we started with a non-empty list
                                    |> Maybe.withDefault ( CG.val "This should never happen", [] )
                                    |> List.NonEmpty.foldl1 Shared.concatenateLists
                    in
                    List.NonEmpty.map associateHtmlKindWithSegment value
                        |> concatHtmlKindSegments
                        |> (case Dict.toList placeholders of
                                [] ->
                                    case addHtmlAttrsIfNeeded [] of
                                        [] ->
                                            identity

                                        nonEmpty ->
                                            CG.lambda nonEmpty

                                [ ( single, _ ) ] ->
                                    CG.lambda <| addIntlIfNeeded <| [ CG.varPattern <| lookup single ] ++ addHtmlAttrsIfNeeded []

                                _ ->
                                    CG.lambda <|
                                        addIntlIfNeeded <|
                                            (if Dict.isEmpty specificPlaceholdersForThisLanguage then
                                                CG.allPattern

                                             else
                                                CG.varPattern dataName
                                            )
                                                :: addHtmlAttrsIfNeeded []
                           )

                i18nDecls : List CG.Declaration
                i18nDecls =
                    Dict.NonEmpty.map i18nDeclForLang translationSet
                        |> Dict.NonEmpty.toList
                        |> List.sortBy Tuple.first
                        |> List.map Tuple.second
            in
            { ctx | file = ctx.file |> Shared.addDeclarations i18nDecls }


toFile : Context -> NonEmptyState () -> CG.File
toFile context state =
    Unique.new ()
        |> Names.withUniqueNames (Dict.NonEmpty.keys state)
            context.names
            (\names _ ->
                { intl = context.intl
                , state = state
                , file = Shared.emptyFile context
                , names = names
                , i18nArgLast = context.i18nArgLast
                }
            )
        |> toFileUnique


translationToRecordTypeAnn : NonEmptyState () -> TKey -> CG.TypeAnnotation
translationToRecordTypeAnn state key =
    let
        placeholders =
            State.collectiveTranslationSet state
                |> State.interpolationMap
                |> Dict.get key
                |> Maybe.withDefault Dict.empty
                |> Dict.toList
                |> List.sortBy Tuple.first

        htmlIds =
            State.getHtmlIds state
                |> Dict.get key
                |> Maybe.withDefault Set.empty

        htmlReturnType nonEmptyIds =
            CG.funAnn (Shared.htmlRecordTypeAnn nonEmptyIds)
                (CG.listAnn <| CG.fqTyped [ "Html" ] "Html" [ CG.typed "Never" [] ])
    in
    case ( placeholders, List.NonEmpty.fromList <| Set.toList htmlIds ) of
        ( [], Nothing ) ->
            CG.stringAnn

        ( [], Just nonEmptyIds ) ->
            htmlReturnType nonEmptyIds

        ( [ ( _, kind ) ], Nothing ) ->
            CG.funAnn (InterpolationKind.toTypeAnn kind) CG.stringAnn

        ( [ ( _, kind ) ], Just nonEmptyIds ) ->
            CG.funAnn (InterpolationKind.toTypeAnn kind) (htmlReturnType nonEmptyIds)

        ( many, Nothing ) ->
            many
                |> List.map (Tuple.mapSecond InterpolationKind.toTypeAnn)
                |> (\fields -> CG.funAnn (CG.recordAnn fields) CG.stringAnn)

        ( many, Just nonEmptyIds ) ->
            many
                |> List.map (Tuple.mapSecond InterpolationKind.toTypeAnn)
                |> (\fields -> CG.funAnn (CG.recordAnn fields) (htmlReturnType nonEmptyIds))


type HtmlKind
    = NoHtml
    | ContainsHtml
    | IsHtml
