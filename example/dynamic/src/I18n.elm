module I18n exposing (I18n, Language(..), decoder, greeting, init, languageFromString, languageSwitchInfo, languageToString, languages, load, order, static)

{-| This file was generated by elm-i18n.


-}

import Array
import Http
import Json.Decode
import List
import String
import Tuple


type I18n
    = I18n (Array.Array String)


init : I18n
init =
    I18n Array.empty


type Language
    = De
    | En


languages : List Language
languages =
    [ De, En ]


languageToString : Language -> String
languageToString lang_ =
    case lang_ of
        De ->
            "de"

        En ->
            "en"


languageFromString : String -> Maybe Language
languageFromString lang_ =
    case lang_ of
        "de" ->
            Just De

        "en" ->
            Just En

        _ ->
            Nothing


fallbackValue_ : String
fallbackValue_ =
    "..."


decoder : Json.Decode.Decoder I18n
decoder =
    Json.Decode.array Json.Decode.string |> Json.Decode.map I18n


load : { language : Language, path : String, onLoad : Result Http.Error I18n -> msg } -> Cmd msg
load opts_ =
    Http.get
        { expect = Http.expectJson opts_.onLoad decoder
        , url = opts_.path ++ "/messages." ++ languageToString opts_.language ++ ".json"
        }


replacePlaceholders : List String -> String -> String
replacePlaceholders list_ str_ =
    List.foldl
        (\val_ ( i_, acc_ ) -> ( i_ + 1, String.replace ("{{" ++ String.fromInt i_ ++ "}}") val_ acc_ ))
        ( 0, str_ )
        list_
        |> Tuple.second


greeting : I18n -> String -> String
greeting (I18n i18n_) name_ =
    case Array.get 0 i18n_ of
        Just translation_ ->
            replacePlaceholders [ name_ ] translation_

        Nothing ->
            fallbackValue_


languageSwitchInfo : I18n -> String -> String
languageSwitchInfo (I18n i18n_) currentLanguage_ =
    case Array.get 1 i18n_ of
        Just translation_ ->
            replacePlaceholders [ currentLanguage_ ] translation_

        Nothing ->
            fallbackValue_


order : I18n -> { a | language : String, name : String } -> String
order (I18n i18n_) placeholders_ =
    case Array.get 2 i18n_ of
        Just translation_ ->
            replacePlaceholders [ placeholders_.language, placeholders_.name ] translation_

        Nothing ->
            fallbackValue_


static : I18n -> String
static (I18n i18n_) =
    case Array.get 3 i18n_ of
        Just translation_ ->
            translation_

        Nothing ->
            fallbackValue_
