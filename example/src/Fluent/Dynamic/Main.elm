module Fluent.Dynamic.Main exposing (main)

import Browser exposing (Document)
import Fluent.Dynamic.I18n as I18n exposing (I18n, Language)
import Html exposing (button, div, input, option, p, select, text)
import Html.Attributes exposing (class, selected, value)
import Html.Events exposing (onClick, onInput)
import Html.Events.Extra exposing (onChange)
import Http
import Intl exposing (Intl)
import Time


type Msg
    = GotTranslations (Result Http.Error (I18n -> I18n))
    | ChangedName String
    | ChangeLanguage Language


type alias Model =
    { i18n : I18n
    , intl : Intl
    , name : String
    , language : Language
    }


init : Flags -> ( Model, Cmd Msg )
init { intl, language } =
    let
        lang =
            I18n.languageFromString language |> Maybe.withDefault I18n.En
    in
    ( { i18n = I18n.init intl lang, name = "", language = lang, intl = intl }
    , I18n.loadDemo { language = lang, path = "/i18n", onLoad = GotTranslations }
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        GotTranslations (Ok addTranslations) ->
            ( { model | i18n = addTranslations model.i18n }, Cmd.none )

        GotTranslations (Err _) ->
            ( model, Cmd.none )

        ChangedName name ->
            ( { model | name = name }, Cmd.none )

        ChangeLanguage language ->
            ( { model | language = language }, I18n.loadDemo { language = language, path = "/i18n", onLoad = GotTranslations } )


view : Model -> Document Msg
view ({ i18n } as model) =
    let
        currentLangString =
            I18n.languageToString model.language
    in
    { title = "Example: " ++ currentLangString
    , body =
        [ div [ class "row" ] (List.map (\lang -> button [ onClick <| ChangeLanguage lang ] [ text <| I18n.languageToString lang ]) I18n.languages)
        , div [ class "row" ] [ text <| I18n.staticTermKey i18n ]
        , div [ class "row" ] [ text <| I18n.dynamicTermKey i18n "\"interpolated\"" ]
        , div [ class "row" ] [ text <| I18n.nestedTermKey i18n ]
        , div [ class "row" ]
            [ text <|
                I18n.attributes i18n
                    ++ ": "
                    ++ I18n.attributesTitle i18n
                    ++ " | "
                    ++ I18n.attributesWithVarAndTerm i18n "Variable"
            ]
        , div [ class "row" ] [ text <| I18n.dateTimeFun i18n (Time.millisToPosix 0) ]
        , div [ class "row" ] [ text <| I18n.numberFun i18n 0.42526 ]
        , div [ class "row" ] [ text <| I18n.compileTimeDatesAndNumbers i18n ]
        ]
    }


type alias Flags =
    { language : String
    , intl : Intl
    }


main : Program Flags Model Msg
main =
    Browser.document
        { init = init
        , update = update
        , subscriptions = always Sub.none
        , view = view
        }