module Core.Asm.Positive where

import Base
import Core.Asm.Base
import Core.Eval.Positive qualified as Eval

allTests :: TestTree
allTests = testGroup "JuvixCore to JuvixAsm positive tests" (map liftTest (Eval.filterOutTests ignoredTests Eval.tests))

ignoredTests :: [String]
ignoredTests =
  [ "Match with complex patterns"
  ]

liftTest :: Eval.PosTest -> TestTree
liftTest _testEval =
  fromTest
    Test
      { _testEval
      }