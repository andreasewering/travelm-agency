module TutorialView exposing (Events, Model, view)

import Dict exposing (Dict)
import File exposing (InputFile, OutputFile)
import Html exposing (Html)
import Html.Attributes exposing (class, href)
import Html.Events
import InputType exposing (InputType)
import Json.Decode
import Material.Icons
import Material.Icons.Types exposing (Coloring(..))
import Maybe.Extra
import Routes


type alias Model =
    { headline : String
    , route : Routes.Route
    , inputTypes : List InputType
    , activeInputType : InputType
    , inputFiles : Dict String InputFile
    , activeInputFilePath : String
    , caretPosition : Int
    , outputFiles : Dict String OutputFile
    , activeOutputFilePath : String
    , basePath : String
    }


type alias Events msg =
    { onEditInput : { filePath : String, newContent : String, caretPosition : Int } -> msg
    , onSwitchInput : String -> msg
    , onSwitchOutput : String -> msg
    , onSwitchInputType : InputType -> msg
    }


view : Model -> Events msg -> List (Html msg) -> List (Html msg)
view model events explanationText =
    let
        activeInputFile =
            Dict.get model.activeInputFilePath model.inputFiles

        activeOutputFile =
            Dict.get model.activeOutputFilePath model.outputFiles

        navigation =
            Html.div [ class "nav" ]
                [ case Routes.previous model.route of
                    Just previous ->
                        Html.a [ href <| Routes.toUrl model.basePath previous, class "arrow" ] [ Material.Icons.arrow_back 50 Inherit ]

                    Nothing ->
                        Material.Icons.arrow_back 50 Inherit
                , Html.text model.headline
                , case Routes.next model.route of
                    Just next ->
                        Html.a [ href <| Routes.toUrl model.basePath next, class "arrow" ] [ Material.Icons.arrow_forward 50 Inherit ]

                    Nothing ->
                        Material.Icons.arrow_forward 50 Inherit
                ]

        inputTypeSelect =
            Html.select
                [ Html.Events.onInput
                    (InputType.fromString
                        >> Maybe.withDefault model.activeInputType
                        >> events.onSwitchInputType
                    )
                ]
            <|
                List.map
                    (\inputType ->
                        Html.option
                            [ Html.Attributes.selected <| inputType == model.activeInputType ]
                            [ Html.text <| InputType.toString inputType ]
                    )
                    model.inputTypes

        inputHeader =
            Html.div [ class "file-header-container" ] <|
                List.map
                    (\( path, file ) ->
                        viewFileHeader
                            { fileName = File.inputFileToPath file
                            , isActive = path == model.activeInputFilePath
                            , onClick = events.onSwitchInput <| File.inputFileToPath file
                            }
                    )
                <|
                    Dict.toList
                        model.inputFiles

        outputHeader =
            Html.div [ class "file-header-container" ] <|
                List.map
                    (\( path, file ) ->
                        viewFileHeader
                            { fileName = File.outputFileToPath file
                            , isActive = path == model.activeOutputFilePath
                            , onClick = events.onSwitchOutput <| File.outputFileToPath file
                            }
                    )
                <|
                    Dict.toList
                        model.outputFiles

        inputCode =
            case activeInputFile of
                Just file ->
                    highlightedCode
                        { language = file.extension
                        , code = file.content
                        , caretPosition = Just model.caretPosition
                        , onEdit =
                            Just <|
                                \newContent caretPosition ->
                                    events.onEditInput
                                        { filePath = File.inputFileToPath file
                                        , newContent = newContent
                                        , caretPosition = caretPosition
                                        }
                        }

                Nothing ->
                    Html.div [] []

        outputCode =
            case activeOutputFile of
                Just file ->
                    highlightedCode
                        { language = file.extension
                        , code = file.content
                        , caretPosition = Nothing
                        , onEdit = Nothing
                        }

                Nothing ->
                    Html.div [] []
    in
    [ Html.div [ class "content" ]
        [ Html.div [ class "left-sidebar" ]
            [ navigation, Html.div [ class "explanation" ] explanationText ]
        , Html.div [ class "playground" ]
            [ inputHeader
            , inputCode
            , outputHeader
            , outputCode
            ]
        ]
    ]


viewFileHeader : { fileName : String, isActive : Bool, onClick : msg } -> Html msg
viewFileHeader { fileName, isActive, onClick } =
    let
        classList =
            Html.Attributes.classList [ ( "file-header", True ), ( "active", isActive ) ]
    in
    Html.div [ Html.Events.onClick onClick, classList ] [ Html.text fileName ]


highlightedCode :
    { language : String
    , code : String
    , caretPosition : Maybe Int
    , onEdit : Maybe (String -> Int -> msg)
    }
    -> Html msg
highlightedCode { language, code, caretPosition, onEdit } =
    Html.node "highlighted-code"
        ([ Html.Attributes.attribute "lang" language
         , Html.Attributes.attribute "code" code
         ]
            ++ Maybe.Extra.toList (Maybe.map (Html.Attributes.attribute "pos" << String.fromInt) caretPosition)
            ++ Maybe.withDefault []
                (Maybe.map
                    (\callback ->
                        [ Html.Events.on "edit"
                            (Json.Decode.map2 callback
                                (Json.Decode.at [ "detail", "content" ] Json.Decode.string)
                                (Json.Decode.at [ "detail", "caretPos" ] Json.Decode.int)
                            )
                        , Html.Attributes.attribute "editable" "true"
                        ]
                    )
                    onEdit
                )
        )
        []
