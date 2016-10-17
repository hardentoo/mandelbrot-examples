module AccTransformScript where

import           Prelude hiding (repeat)

import           HERMIT.API
import           HERMIT.API.Types

import           Control.Monad (forever)

fullBetaReduce :: Rewrite LCore
fullBetaReduce = betaReduce >>> letSubst

script :: Shell ()
script = do
  apply flattenModule

  eval "set-pp-type Omit"

  setPath $ rhsOf "main"
  apply . oneTD $ unfoldRuleUnsafe "abs-intro"

  apply . oneTD $ unfoldWith "pointColor"

  mapM_ (apply . repeat . oneTD . unfoldRuleUnsafe)
        [ ">=*-intro"
        , "+-intro"
        , "*-intro"
        , "--intro"
        , "/-intro"
        ]

  apply . repeat $ oneTD caseFloat
  apply . repeat $ oneTD letFloatCase

  apply $ repeat (extractR $ focus (applicationOf "abs")
                                   (promote (caseFloatArgLemma "abs-lemma" <+ letFloat)))

  proofCmd assume

  apply smash

  -- Recursion --
  apply $ oneTD fixIntro
  apply $ oneTD letSubst -- See if this can be combined into the above line so
                         -- correct let is always substituted.

  apply . oneTD $ unfoldRuleUnsafe "fix-abs-rep-intro"
  apply . repeat . oneTD $ fullBetaReduce

  apply $ extractR $ focus (applicationOf "abs")
                           (promote (caseFloatArgLemma "abs-lemma" <+ letFloat))
  proofCmd assume

  apply . repeat . oneTD $ unfoldRuleUnsafe "abs-if->cond"

  apply . oneTD $ unfoldRuleUnsafe "recCall-intro"
  apply smash

  apply . oneTD $ unfoldRuleUnsafe "recCall-triple-rep-float"

  apply . repeat . oneTD $ unfoldRuleUnsafe "abs-rep-elim"

  apply smash

  apply . oneTD $ unfoldRuleUnsafe "while-intro"
  apply $ oneTD fullBetaReduce

  scope $ do
    setPath $ applicationOf "while"
    -- mapM_ sendCrumb [appFun, appArg, lamBody, appArg]
    apply . oneTD $ unfoldRuleUnsafe "triple-rep"
    apply $ oneTD caseReduce

  apply . repeat . oneTD $ unfoldRuleUnsafe "efirst-float-in"
  apply . repeat . oneTD $ unfoldRuleUnsafe "esecond-float-in"
  apply . repeat . oneTD $ unfoldRuleUnsafe "ethird-float-in"


  apply . repeat . oneTD $ unfoldRuleUnsafe "abs-float-triple"
  apply . repeat . oneTD $ unfoldRuleUnsafe "abs-rep-elim"

  apply . oneTD $ caseElimInlineScrutinee


  apply $ repeat ((oneTD (unfoldRuleUnsafe "condBool-intro"))
                  >>>
                  (oneTD (unfoldRuleUnsafe "condBool-elim" >>> abstract "z")))

  apply . repeat . oneTD $ unfoldRuleUnsafe "cond'->cond"

  apply . repeat . oneTD $ unfoldRuleUnsafe "cond-float-else"
  apply . repeat . oneTD $ unfoldRuleUnsafe "recCondF-float-else"

  apply . oneTD $ unfoldRuleUnsafe "dummyArg-intro"

  scope $ do
    setPath $ applicationOf "grabbedCond"
    sendCrumb appArg
    apply $ oneTD fullBetaReduce

  apply . oneTD $ unfoldRuleUnsafe "grab-cond"

  mapM_ unprovenAssume
        [ "abs-intro"
        , ">=*-intro"
        , "+-intro"
        , "*-intro"
        , "--intro"
        , "/-intro"
        , "fix-abs-rep-intro"
        , "abs-if->cond"
        , "recCall-intro"
        , "recCall-triple-rep-float"
        , "abs-rep-elim"
        , "while-intro"
        , "triple-rep"
        , "efirst-float-in"
        , "esecond-float-in"
        , "ethird-float-in"
        ]

unprovenAssume :: LemmaName -> Shell ()
unprovenAssume lemmaName = do
  shellEffect $ proveLemma lemmaName
  proofCmd assume

