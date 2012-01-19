{-# LANGUAGE GeneralizedNewtypeDeriving, RankNTypes, ImpredicativeTypes #-}
module Supercompile.Drive.Process3 (supercompile) where

import Supercompile.Drive.Match
import Supercompile.Drive.Split
import Supercompile.Drive.Process

import Supercompile.Core.FreeVars
import Supercompile.Core.Size (fvedTermSize)
import Supercompile.Core.Syntax
import Supercompile.Core.Tag

import Supercompile.Evaluator.Deeds
import Supercompile.Evaluator.Residualise
import Supercompile.Evaluator.Syntax
import Supercompile.Evaluator.FreeVars

import Supercompile.Termination.Generaliser (Generaliser)
import Supercompile.Termination.TagBag (stateTags)
import Supercompile.Termination.Combinators hiding (generatedKey)
import qualified Supercompile.Termination.Combinators as Combinators

import Supercompile.StaticFlags
import Supercompile.Utilities

import Var        (varName)
import Id         (mkLocalId)
import Name       (Name, mkSystemVarName, getOccString)
import FastString (mkFastString)
import Util       (sndOf3)

import Control.Monad (join)

import Data.Function (on)
import qualified Data.Map as M
import Data.Monoid (mempty)


{--}
type ProcessHistory = GraphicalHistory (NodeKey, (String, State, forall b. Generaliser -> ScpM b))

pROCESS_HISTORY :: ProcessHistory
pROCESS_HISTORY = mkGraphicalHistory (cofmap sndOf3 wQO)

generatedKey :: ProcessHistory -> NodeKey
generatedKey = Combinators.generatedKey
{--}
{-
type ProcessHistory = LinearHistory (NodeKey, State)

pROCESS_HISTORY :: ProcessHistory
pROCESS_HISTORY = mkLinearHistory (cofmap snd wQO)

generatedKey :: ProcessHistory -> NodeKey
generatedKey _ = 0
-}

data Promise = P {
    fun        :: Var,      -- Name assigned in output program
    abstracted :: [AbsVar], -- Abstracted over these variables
    meaning    :: State,    -- Minimum adequate term
    dumped     :: Bool      -- Already rolled back, and hence inaccessible?
  }


data MemoState = MS {
    promises :: [Promise],
    hNames   :: Stream Name
  }

promise :: (State, State) -> MemoState -> (Promise, MemoState)
promise (state, reduced_state) ms = (p, ms')
  where (vs_list, h_ty) = stateAbsVars (Just (stateLambdaBounders reduced_state)) state
        h_name :< h_names' = hNames ms
        x = mkLocalId h_name h_ty
        p = P {
            fun        = x,
            -- We mark as dead any of those variables that are not in the stateLambdaBounders of
            -- the *reduced* state. This serves two purposes:
            --   1. The tieback we do right here can supply dummy values to those parameters rather
            --      than applying the free variables. This may make some bindings above us dead.
            --
            --   2. We can get rid of the code in renameAbsVar that downgrades live AbsVars to dead
            --      ones if they are not present in the renaming: only dead AbsVars are allowed to
            --      be absent in the renaming.
            abstracted = vs_list,
            meaning    = reduced_state,
            dumped     = False
          }
        ms' = MS {
            promises = p : promises ms,
            hNames   = h_names'
          }


newtype FulfilmentState = FS {
    fulfilments :: [(Var, FVedTerm)]
  }

fulfill :: Promise -> (Deeds, FVedTerm) -> FulfilmentState -> ((Deeds, FVedTerm), FulfilmentState)
fulfill p (deeds, e_body) fs = ((deeds, fun p `applyAbsVars` abstracted p), FS { fulfilments = (fun p, absVarLambdas (abstracted p) e_body) : fulfilments fs })


type StopCount = Int

data ScpState = ScpState {
    scpMemoState :: MemoState,
    scpProcessHistory :: ProcessHistory,
    scpFulfilmentState :: FulfilmentState,
    -- Debugging aids below this line:
    scpResidTags :: ResidTags,
    scpParentChildren :: ParentChildren
  }

data ScpEnv = ScpEnv {
    scpStopCount :: StopCount,
    scpNodeKey :: NodeKey,
    scpParents :: [Var],
    scpAlreadySpeculated :: AlreadySpeculated,
    -- Debugging aids below this line:
    scpTagAnnotations :: TagAnnotations
  }

type ScpResType = (FVedTerm, ScpState)

newtype ScpM a = ScpM { unScpM :: StateT ScpState
                                         (ReaderT ScpEnv (ContT ScpResType Identity)) a }
               deriving (Functor, Applicative, Monad)

instance MonadStatics ScpM where
    bindCapturedFloats _fvs mx = liftM ((,) []) mx -- FIXME: do something other than hope for the best
    monitorFVs = liftM ((,) emptyVarSet)

runScpM :: TagAnnotations -> ScpM FVedTerm -> FVedTerm
runScpM tag_anns me = fvedTermSize e' `seq` trace ("Deepest path:\n" ++ showSDoc (deepestPath fulfils (scpParentChildren s')) ++
                                                   "\nDepth histogram:\n" ++ showSDoc (depthHistogram (scpParentChildren s'))) e'
  where h_names = listToStream $ zipWith (\i uniq -> mkSystemVarName uniq (mkFastString ('h' : show (i :: Int))))
                                         [1..] (uniqsFromSupply hFunctionsUniqSupply)
        ms = MS { promises = [], hNames = h_names }
        hist = pROCESS_HISTORY
        fs = FS { fulfilments = [] }
        parent = generatedKey hist
        (e, s') = unI $ runContT $ unReaderT (unStateT (unScpM me) (ScpState ms hist fs emptyResidTags emptyParentChildren)) (ScpEnv 0 parent [] nothingSpeculated tag_anns)
        fulfils = fulfilments (scpFulfilmentState s')
        e' = letRec fulfils e


callCCM :: ((forall b. a -> ScpM b) -> ScpM a) -> ScpM a
callCCM act = ScpM $ StateT $ \s -> ReaderT $ \env -> callCC (\jump_back -> unReaderT (unStateT (unScpM (act (\a -> ScpM $ StateT $ \s' -> ReaderT $ \_ -> jump_back (a, s' `rolledBackTo` s)))) s) env)

catchM :: ((forall b. c -> ScpM b) -> ScpM a) -- ^ Action to try: supplies a function than can be called to "raise an exception". Raising an exception restores the original ScpEnv and ScpState
       -> (c -> ScpM a)                       -- ^ Handler deferred to if an exception is raised
       -> ScpM a                              -- ^ Result from either the main action or the handler
catchM try handler = do
    ei_exc_res <- callCCM $ \jump_back -> fmap Right (try (jump_back . Left))
    case ei_exc_res of
      Left exc  -> handler exc
      Right res -> return res

rolledBackTo :: ScpState -> ScpState -> ScpState
rolledBackTo s' s = ScpState {
      scpMemoState = MS {
          promises = mapMaybe (\p -> if fun p == fun (head (promises (scpMemoState s'))) -- The most recent promise in s' always has no work done on it, so don't report dumping
                                      then Nothing
                                      else Just $ if fun p `elemVarSet` rolled_back then p { dumped = True } else p) (promises (scpMemoState s')),
          hNames   = hNames (scpMemoState s')
        },
      scpProcessHistory = scpProcessHistory s,
      scpFulfilmentState = FS {
          fulfilments = rolled_fulfilments
        },
      scpResidTags      = scpResidTags s', -- FIXME: not totally accurate
      scpParentChildren = scpParentChildren s'
    }
  where
    -- We have to roll back any promise on the "stack" above us. We don't have access to the stack directly, but we can compute this set
    -- of promises by looking at *new* promises that are as yet unfulfilled:
    init_rolled_back = (minusVarSet `on` (mkVarSet . map fun . promises . scpMemoState)) s' s `minusVarSet` mkVarSet (map fst (fulfilments (scpFulfilmentState s')))
    -- NB: rolled_back includes both unfulfilled promises rolled back from the stack and fulfilments that have to be dumped as a result
    (rolled_fulfilments, rolled_back) = pruneFulfilments (fulfilments (scpFulfilmentState s')) init_rolled_back

    pruneFulfilments fulfilments rolled_back
      | null dump = (if isEmptyVarSet rolled_back then id else pprTraceSC ("dumping " ++ show (sizeVarSet rolled_back) ++ " fulfilments:") (ppr rolled_back))
                    (fulfilments, rolled_back)
      | otherwise = pruneFulfilments keep (rolled_back `unionVarSet` mkVarSet (map fst dump))
      where (dump, keep) = partition (\(_, e) -> fvedTermFreeVars e `intersectsVarSet` rolled_back) fulfilments

scpDepth :: ScpEnv -> Int
scpDepth = length . scpParents

traceRenderM :: Outputable a => String -> a -> ScpM ()
traceRenderM msg x = ScpM $ StateT $ \s -> ReaderT $ \env -> pprTraceSC (replicate (scpDepth env) ' ' ++ msg) (pPrint x) $ pure ((), s) -- TODO: include depth, refine to ScpM monad only

addParentM :: Promise -> (State -> ScpM (Bool, (Deeds, FVedTerm))) -> State -> ScpM (Deeds, FVedTerm)
addParentM p opt state = ScpM $ StateT $ \s -> ReaderT $ add_parent s
  where
    add_parent s env
      | maybe False (scpDepth env >=) dEPTH_LIIMT
      , let (deeds, _, e) = residualiseState state
      = return ((deeds, e), s)
      | otherwise
      = trace ("depth: " ++ show (scpDepth env) ++ ' ' : showSDoc (parens (hsep (map ppr (scpParents env))))) $
        unReaderT (unStateT (unScpM (opt state)) s)
                  (env { scpParents = fun p : scpParents env }) >>= \((gen, res), s') -> return (res, s' { scpParentChildren = addChild (safeHead (scpParents env)) (fun p) (meaning p) gen (scpParentChildren s') })

fulfillM :: Promise -> (Deeds, FVedTerm) -> ScpM (Deeds, FVedTerm)
fulfillM p res = ScpM $ StateT $ \s -> case fulfill p res (scpFulfilmentState s) of (res', fs') -> return (res', s { scpFulfilmentState = fs' })

terminateM :: String -> State -> (forall b. Generaliser -> ScpM b) -> ScpM a -> (String -> State -> (forall b. Generaliser -> ScpM b) -> ScpM a) -> ScpM a
terminateM h state rb mcont mstop = ScpM $ StateT $ \s -> ReaderT $ \env -> case terminate (scpProcessHistory s) (scpNodeKey env, (h, state, rb)) of
        Stop (_, (shallow_h, shallow_state, shallow_rb))
          -> trace ("stops: " ++ show (scpStopCount env)) $
             unReaderT (unStateT (unScpM (mstop shallow_h shallow_state shallow_rb)) s)                                 (env { scpStopCount = scpStopCount env + 1}) -- FIXME: prevent rollback?
        Continue hist'
          -> unReaderT (unStateT (unScpM mcont)                                      (s { scpProcessHistory = hist' })) (env { scpNodeKey = generatedKey hist' })
  -- TODO: record the names of the h-functions on the way to the current one instead of a Int depth

speculateM :: State -> (State -> ScpM a) -> ScpM a
speculateM state mcont = ScpM $ StateT $ \s -> ReaderT $ \env -> case speculate (scpAlreadySpeculated env) (mempty, state) of (already', (_stats, state')) -> unReaderT (unStateT (unScpM (mcont state')) s) (env { scpAlreadySpeculated = already' })


sc :: State -> ScpM (Deeds, FVedTerm)
sc = memo sc' . gc -- Garbage collection necessary because normalisation might have made some stuff dead

sc' :: Maybe String -> State -> ScpM (Bool, (Deeds, FVedTerm))
sc' mb_h state = case mb_h of
  Nothing -> speculateM (reduce state) $ \state -> my_split state sc
  Just h  -> flip catchM try_generalise $ \rb ->
               terminateM h state rb
                 (speculateM (reduce state) $ \state -> my_split state sc)
                 (\shallow_h shallow_state shallow_rb -> trce shallow_h shallow_state $
                                                         (if sC_ROLLBACK then shallow_rb else try_generalise) (mK_GENERALISER shallow_state state))
  where
    try_generalise gen = maybe (trace "sc-stop(split)" $ my_split state)
                               (trace "sc-stop(gen)")
                               (my_generalise gen state)
                               sc

    trce shallow_h shallow_state = pprTraceSC ("Embedding:" ++ shallow_h)
                                              ({- ppr (stateTags shallow_state) <+> text "<|" <+> ppr (stateTags state) $$ -}
                                               hang (text "Before:") 2 (trce1 shallow_state) $$
                                               hang (text "After:")  2 (trce1 state) $$
                                               (case unMatch (match' (snd (reduceForMatch shallow_state)) (snd (reduceForMatch state))) of Left why -> text why))
    trce1 state = pPrintFullState quietStatePrettiness state $$ pPrintFullState quietStatePrettiness (snd (reduceForMatch state))

    -- NB: we could try to generalise against all embedded things in the history, not just one. This might make a difference in rare cases.
    my_generalise gen = liftM (\splt -> liftM ((,) True)  . insert_tags . splt) . generalise gen
    my_split      opt =                 liftM ((,) False) . insert_tags . split opt
    --insert_tags = liftM (\(_, deeds, e') -> (deeds, e'))
    insert_tags mx = do
      (resid_tags, deeds, e') <- mx
      ScpM $ StateT $ \s -> ReaderT $ \env -> let resid_tags' = scpResidTags s `plusResidTags` resid_tags
                                              in trace (tagSummary (scpTagAnnotations env) 1 30 resid_tags' ++ "\n" ++ childrenSummary (scpParentChildren s)) $
                                                 return ((), s { scpResidTags = resid_tags' })
      return (deeds, e')

-- Note [Prevent rollback loops by only rolling back when generalising]
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
--
-- I tried to think about another way to fix rollback.
--  1. If we split <x |-> v[x] | \underbar{x} | > to < | v[x] | update x >
--     .. then we have the invariant that the children of a split are <= size of the parent
--        (we presently don't have this because we duplicate the bodies of heap-bound lambdas)
--  2. Then we can say that the children of any *generalise* have size strictly < that of the parent
--  3. As a result we can recover the termination argument by saying that:
--     a) For any potentially infinite final chain of states all related by "split"/"generalise..
--     b) We can chop it into segments of consecutive "split"s
--       i) Each segment must be of finite length (because of the alpha-renaming-tieback property and
--          the fact that each state in the chain is a syntactic subset of the initial one)
--       ii) There must be a finite number of segments, because each time we generalise we reduce size
--           by at least one, and the intervening splits don't increase it
--       iii) QED (The final chain is finite)
--
-- This is a really beautiful plan. The problem I've found with it is that we can't do 1) because of the
-- problem mentioned in the section about Arjan's idea in the splitter --- i.e. we can do:
--   1. SC (let x = v in x) 
--   2. Reduce to (let x = v in \underbar{x})
--   3. Split to (let x = v in x)
--   4. Tieback to 1), building a worthless loop
--
-- So we should probably work out why the existing supercompiler never builds dumb loops like this, so
-- we can carefully preserve that property when making the Arjan modification.

memo :: (Maybe String -> State -> ScpM (Bool, (Deeds, FVedTerm)))
     ->  State -> ScpM (Deeds, FVedTerm)
memo opt state
  | Skip <- memo_how = liftM snd $ opt Nothing state
  | otherwise = join $ ScpM $ StateT $ \s ->
    -- NB: If tb contains a dead PureHeap binding (hopefully impossible) then it may have a free variable that
    -- I can't rename, so "rename" will cause an error. Not observed in practice yet.

    -- Note [Matching after reduction]
    -- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    --
    -- If we match on States *after* reduction, we might get the following problem. Our initial state could be:
    --
    --  let y = 1; p = (x, y) in snd p
    --
    -- This state has the free variables {x}. However, after reduction+GC it does not have any free variables.
    -- Which set of free variables should we lambda-abstract the h-function over? Well, clearly we have to 
    -- lambda-abstract over the pre-reduction FVs in case that "opt" does not do any reduction and leaves x as a
    -- free variable.
    --
    -- A consequence of this decision is that we have to do something a bit weird at *tieback* site like this one:
    --
    --  let y = 1 in y
    --
    -- To tieback to the h-function for the initial state, we need to supply an x. Luckily, the act of reduction
    -- proves that x is a dead variable and hence we should just be able to supply "undefined".
    --
    -- Note that:
    --  1. Terms that match *after* reduction may not match *before* reduction. This is obvious, and the reason
    --     that we match to reduce before matching in the first place
    --  2. Suprisingly, terms that match *before* reduction may not match *after* reduction! This occurs because
    --     two terms with different distributions of tag may match, but may roll back in different ways in reduce.
    case [ (p, (releaseStateDeed state, fun p `applyAbsVars` map (renameAbsVar rn_lr) (abstracted p)))
         | p <- promises (scpMemoState s)
         , Just rn_lr <- [-- (\res -> if isNothing res then pprTraceSC "no match:" (ppr (fun p)) res else pprTraceSC "match!" (ppr (fun p)) res) $
                          match (meaning p) reduced_state]
         , if dumped p
            then pprTraceSC "tieback-to-dumped" (ppr (fun p)) False
            else True
         ] of (p, res):_ -> pure (do { traceRenderM "=sc" (fun p, PrettyDoc (pPrintFullState quietStatePrettiness state), PrettyDoc (pPrintFullState quietStatePrettiness reduced_state), PrettyDoc (pPrintFullState quietStatePrettiness (meaning p)) {-, res-})
                                     ; return res }, s)
              _          | CheckOnly <- memo_how
                         -> pure (liftM snd $ opt Nothing state, s)
                         | otherwise
                         -> pure (do { traceRenderM ">sc {" (fun p, stateTags state, PrettyDoc (pPrintFullState quietStatePrettiness state))
                                     ; res <- addParentM p (opt (Just (getOccString (varName (fun p))))) state
                                     ; traceRenderM "<sc }" (fun p, PrettyDoc (pPrintFullState quietStatePrettiness state), res)
                                     ; fulfillM p res }, s { scpMemoState = ms' })
                where (p, ms') = promise (state, reduced_state) (scpMemoState s)
  where (state_did_reduce, reduced_state) = reduceForMatch state
        
        -- The idea here is to prevent the supercompiler from building loops when doing instance matching. Without
        -- this, we tend to do things like:
        --
        --  h0 = D[let f = v in f] = let f = h1 in f
        --  h1 = D[let f = v in v] = h0
        --
        -- This fix is inspired by Peter's supercompiler where matching (and indeed termination checking) is only
        -- performed when the focus of evaluation is the name of a top level function. I haven't yet proved that
        -- this is safe in my setting (FIXME). This might be problematic because Peter does not have a private
        -- history for "reduce" like I do.
        --
        --
        -- Version 2 of this change **prevents** tieback when the focus is an indirection. I'm reasonably
        -- sure this is safe because of the way the splitter is defined and the fact that we have the invariant
        -- that indirections never occur in the stack, and only occur in the heap as the whole HB RHS. This,
        -- combined with the fact that they are acyclic seems to be enough to say that any sequence of splits
        -- only has an indirection in the focus a finite number of times. (FIXME: it's OK that we don't check
        -- the termination condition for those states where the stack is empty since reduce won't change the term.
        -- But it's less clear that it is actually OK to skip termination check when we skip tieback in the other case!!)
        --
        --
        -- Version 3 of this fix is to "eagerly" split values in the splitter: when creating a Bracket for a term,
        -- we split immediately if the term is a value. This is sufficient to fix the problem above, and it should
        -- save even *more* memoisations!
        memo_how | dUPLICATE_VALUES_EVALUATOR || not iNSTANCE_MATCHING
                 = CheckAndRemember
                 | eAGER_SPLIT_VALUES
                 = if state_did_reduce then CheckAndRemember else CheckOnly -- EXPERIMENT: don't check for tieback on unreducable states if we eagerly split values (if we don't eagerly split values this can lead to divergence with e.g. (let xs = x:xs in xs))
                 | (_, _, [], qa) <- state -- NB: not safe to use reduced_state!
                 , Answer (_, (_, Indirect _)) <- annee qa
                 = Skip
                 | otherwise
                 = CheckAndRemember

data MemoHow = Skip | CheckOnly | CheckAndRemember

reduceForMatch :: State -> (Bool, State)
reduceForMatch state = second gc $ reduceWithFlag (case state of (_, h, k, e) -> (maxBound, h, k, e)) -- Reduce ignoring deeds for better normalisation

supercompile :: M.Map Var Term -> Term -> Term
supercompile unfoldings e = fVedTermToTerm $ runScpM (tagAnnotations state) $ liftM snd $ sc state
  where state = prepareTerm unfoldings e
