module Juvix.Compiler.Core.Extra
  ( module Juvix.Compiler.Core.Extra,
    module Juvix.Compiler.Core.Extra.Base,
    module Juvix.Compiler.Core.Extra.Recursors,
    module Juvix.Compiler.Core.Extra.Info,
  )
where

import Data.HashSet qualified as HashSet
import Juvix.Compiler.Core.Extra.Base
import Juvix.Compiler.Core.Extra.Info
import Juvix.Compiler.Core.Extra.Recursors
import Juvix.Compiler.Core.Info qualified as Info
import Juvix.Compiler.Core.Language

isClosed :: Node -> Bool
isClosed = not . has freeVars

getFreeVars :: Node -> HashSet Index
getFreeVars n = HashSet.fromList (n ^.. freeVars)

freeVars :: SimpleFold Node Index
freeVars f = ufoldAN' reassemble go
  where
    go k = \case
      Var i idx
        | idx >= k -> Var i <$> f (idx - k)
      n -> pure n

getIdents :: Node -> HashSet Symbol
getIdents n = HashSet.fromList (n ^.. nodeIdents)

nodeIdents :: Traversal' Node Symbol
nodeIdents f = umapLeaves go
  where
    go = \case
      Ident i d -> Ident i <$> f d
      n -> pure n

countFreeVarOccurrences :: Index -> Node -> Int
countFreeVarOccurrences idx = gatherN go 0
  where
    go k acc = \case
      Var _ idx' | idx' == idx + k -> acc + 1
      _ -> acc

-- | increase all free variable indices by a given value
shift :: Index -> Node -> Node
shift 0 = id
shift m = umapN go
  where
    go k n = case n of
      Var i idx | idx >= k -> Var i (idx + m)
      _ -> n

-- | substitute a term t for the free variable with de Bruijn index 0, avoiding
-- variable capture; shifts all free variabes with de Bruijn index > 0 by -1 (as
-- if the topmost binder was removed)
subst :: Node -> Node -> Node
subst t = umapN go
  where
    go k n = case n of
      Var _ idx | idx == k -> shift k t
      Var i idx | idx > k -> Var i (idx - 1)
      _ -> n

-- | reduce all beta redexes present in a term and the ones created immediately
-- downwards (i.e., a "beta-development")
developBeta :: Node -> Node
developBeta = umap go
  where
    go :: Node -> Node
    go n = case n of
      App _ (Lambda _ body) arg -> subst arg body
      _ -> n

etaExpand :: Int -> Node -> Node
etaExpand 0 n = n
etaExpand k n = mkLambdas k (mkApp (shift k n) (map (Var Info.empty) (reverse [0 .. k - 1])))

-- | substitution of all free variables for values in an environment
substEnv :: Env -> Node -> Node
substEnv env
  | null env = id
  | otherwise = umapN go
  where
    go k n = case n of
      Var _ idx | idx >= k -> env !! (idx - k)
      _ -> n

convertClosures :: Node -> Node
convertClosures = umap go
  where
    go :: Node -> Node
    go n = case n of
      Closure i env b -> substEnv env (Lambda i b)
      _ -> n

convertRuntimeNodes :: Node -> Node
convertRuntimeNodes = convertClosures