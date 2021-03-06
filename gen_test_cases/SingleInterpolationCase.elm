module SingleInterpolationCase exposing (main)

import Dict
import Dict.NonEmpty
import State exposing (NonEmptyState)
import Types.Segment exposing (TSegment(..))
import Util.Shared exposing (Generator, buildMain)
import Util.Shared exposing (inlineOpts)
import Util.Shared exposing (dynamicOpts)


main : Generator
main =
    buildMain [inlineOpts, dynamicOpts] state


state : NonEmptyState ()
state =
    Dict.NonEmpty.singleton "messages" <|
        Dict.NonEmpty.singleton
            "en"
            { pairs = Dict.fromList [ ( "text", ( Text "hello ", [ Interpolation "planet", Text "!" ] ) ) ]
            , fallback = Nothing
            , resources = ()
            }
