{-# LANGUAGE PatternSynonyms            #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE CPP                        #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE TypeSynonymInstances       #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TupleSections              #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE DeriveFoldable             #-}
{-# LANGUAGE DeriveTraversable          #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE TupleSections              #-}

module AccPlugin.AccTransform (plugin) where

import           GhcPlugins

import           Data.Array.Accelerate hiding (map, (++), not, filter, fst, snd)
import qualified Data.Array.Accelerate as A

import           Control.Monad

import           HERMIT.Name (newIdH)
import           HERMIT.Monad (LiftCoreM (..))
import           HERMIT.GHC.Typechecker (initTcFromModGuts)

import           Language.KURE
import           Language.KURE.MonadCatch

import           Control.Monad.IO.Class

import           TcRnTypes
import           TcRnMonad
import           TcSMonad
import           TcSimplify
import           TcEvidence
import           FamInst
import           FamInstEnv
import           DsBinds
import           DsMonad (initDsTc)

import           Encoding (zEncodeString)

import           UniqDFM

import           Control.Arrow (first, second)
import           Data.Char (isSpace)

import           ErrUtils
import           Pair
import           Class

import           Control.Monad.Reader

import           Data.List (partition)
import           Data.Maybe (fromMaybe, isJust)

import qualified Language.Haskell.TH.Syntax as TH

import           AccPlugin.WW

import           Language.KURE


-- instance Injection (Bind CoreBndr) (Expr CoreBndr) where
--   inject (NonRec _ e) = e
--   project (Let bnd _) = Just bnd
--   project _           = Nothing

-- instance Injection (Alt CoreBndr) (Expr CoreBndr) where
--   inject (_, _, e) = e

instance Walker c (Expr CoreBndr) where
  -- -- Adapted from HERMIT.Kure:
  -- allR r =
  --   readerT $ \case
  --     App{}   -> appAllR (extractR r) (extractR r)
  --     Lam{}   -> lamAllR idR (extractR r) -- we don't descend into the Var
  --     Let{}   -> letAllR (extractR r) (extractR r)
  --     Case{}  -> caseAllR (extractR r) idR idR (const $ extractR r) -- we don't descend into the case binder or Type
  --     Cast{}  -> castAllR (extractR r) idR -- we don't descend into the Coercion
  --     Tick{}  -> tickAllR idR (extractR r) -- we don't descend into the Tickish
  --     _       -> idR
  --   where

  --     -- | Transform an expression of the form: @App@ 'CoreExpr' 'CoreExpr'
  --     appT t1 t2 f = transform $ \ c -> \case
  --       App e1 e2 -> f <$> applyT t1 c e1 <*> applyT t2 c e2
  --       _         -> fail "not an application."

  --     -- | Rewrite all children of an expression of the form: @App@ 'CoreExpr' 'CoreExpr'
  --     appAllR r1 r2 = appT r1 r2 App
  --     {-# INLINE appAllR #-}

  --     lamT t1 t2 f = transform $ \ c -> \case
  --       Lam v e -> f <$> applyT t1 c v <*> applyT t2 c e
  --       _       -> fail "not a lambda."
  --     {-# INLINE lamT #-}

  --     -- | Rewrite all children of an expression of the form: @Lam@ 'Var' 'CoreExpr'
  --     lamAllR r1 r2 = lamT r1 r2 Lam


  --     letT t1 t2 f = transform $ \ c -> \case
  --       Let bds e -> -- Note we use the *original* context for the binding group.
  --                    -- If the bindings are recursive, they will be added to the context by recT.
  --                    f <$> applyT t1 c bds <*> applyT t2 c e
  --       _         -> fail "not a let node."
  --     {-# INLINE letT #-}

  --     letAllR r1 r2 = letT r1 r2 Let
  --     {-# INLINE letAllR #-}

  --     caseT te tw tty talts f = transform $ \ c -> \case
  --        Case e w ty alts -> f <$> applyT te c e
  --                              <*> applyT tw c w
  --                              <*> applyT tty c ty
  --                              <*> sequence [ applyT (talts n) c alt
  --                                           | (alt,n) <- Prelude.zip alts [0..]
  --                                           ]
  --        _                -> fail "not a case."
  --     {-# INLINE caseT #-}

  --     -- | Rewrite all children of an expression of the form: @Case@ 'CoreExpr' 'Id' 'Type' ['CoreAlt']
  --     caseAllR re rw rty ralts = caseT re rw rty ralts Case
  --     {-# INLINE caseAllR #-}


  --     castT t1 t2 f = transform $ \ c -> \case
  --       Cast e co -> f <$> applyT t1 c e <*> applyT t2 c co
  --       _         -> fail "not a cast."
  --     {-# INLINE castT #-}

  --     castAllR r1 r2 = castT r1 r2 Cast
  --     {-# INLINE castAllR #-}

  --     tickT t1 t2 f = transform $ \ c -> \case
  --       Tick tk e -> f <$> applyT t1 c tk <*> applyT t2 c e
  --       _         -> fail "not a tick."
  --     {-# INLINE tickT #-}

  --     -- | Rewrite all children of an expression of the form: @Tick@ 'CoreTickish' 'CoreExpr'
  --     tickAllR r1 r2 = tickT r1 r2 Tick
  --     {-# INLINE tickAllR #-}

  allR r = rewrite $ \c expr ->
    case expr of
      Var {} -> pure expr
      Lit {} -> pure expr
      Type {} -> pure expr
      Coercion {} -> pure expr
      App f x -> App <$> applyR (extractR r) c f <*> applyR (extractR r) c x
      Lam n x -> Lam n <$> applyR (extractR r) c x
      Let bnd x -> Let bnd <$> applyR (extractR r) c x
      Case d wild ty alts ->
        Case <$> applyR (extractR r) c d
             <*> pure wild
             <*> pure ty
             <*> mapM (\(ac, bnds, e) ->
                       (ac, bnds, ) <$> applyR (extractR r) c e)
                      alts
      Cast e coer -> Cast <$> applyR (extractR r) c e <*> pure coer
      Tick t e    -> Tick t <$> applyR (extractR r) c e

data PluginEnv
    = PluginEnv
      { pluginModGuts :: ModGuts
      }

newtype PluginM a = PluginM { runPluginM :: ReaderT PluginEnv CoreM (KureM a) }
    deriving Functor
    -- deriving (Functor, Applicative, Monad
    --          ,MonadIO, MonadReader PluginEnv)

instance Applicative PluginM where
  pure = PluginM . pure . pure
    -- TODO: Make sure this is right:
  PluginM f <*> PluginM x = PluginM (fmap (<*>) f <*> x)

instance Monad PluginM where
  return = pure
  PluginM x >>= f = PluginM $
    let g y = case f y of PluginM m -> m
    in
      -- TODO: Make sure 'liftKureM' is what we want here.
    ReaderT $ \a -> runReaderT (x >>= \k -> liftKureM k >>= g) a

  fail s = PluginM $ ReaderT $ \_ -> pure (fail s :: KureM a)

instance MonadIO PluginM where
  liftIO x = PluginM (liftIO (fmap pure x))

instance MonadThings PluginM where
  lookupThing   = liftCoreM . lookupThing
  lookupId      = liftCoreM . lookupId
  lookupDataCon = liftCoreM . lookupDataCon
  lookupTyCon   = liftCoreM . lookupTyCon

class HasHscEnv m where
  getHscEnv' :: m HscEnv

instance HasHscEnv CoreM where
  getHscEnv' = getHscEnv

instance HasHscEnv PluginM where
  getHscEnv' = liftCoreM getHscEnv'

instance MonadUnique PluginM where
  getUniqueSupplyM = liftCoreM getUniqueSupplyM

instance HasDynFlags PluginM where
  getDynFlags = liftCoreM getDynFlags

getModGuts :: PluginM ModGuts
getModGuts = PluginM $ ReaderT (return . return . pluginModGuts)

instance MonadCatch PluginM where
  catchM (PluginM p) k =
    join . PluginM $ ReaderT $ \ctx -> do
            x <- runReaderT p ctx
            pure . pure $ runKureM pure k x

instance LiftCoreM PluginM where
  liftCoreM x = PluginM . (ReaderT . const) . fmap pure $ x

-- | For easier debugging
quickPrint :: (HasDynFlags m, MonadIO m, Outputable a) => a -> m ()
quickPrint a = do
  dynFlags <- getDynFlags
  liftIO $ print (runSDoc (ppr a) (initSDocContext dynFlags cmdlineParserStyle))

quickShow :: (HasDynFlags m, MonadIO m, Outputable a) => a -> m String
quickShow a = do
  dynFlags <- getDynFlags
  return . show $ runSDoc (ppr a) (initSDocContext dynFlags cmdlineParserStyle)

plugin :: Plugin
plugin = defaultPlugin
  { installCoreToDos = install
  }

install :: [CommandLineOption] -> [CoreToDo] -> CoreM [CoreToDo]
install _ todo = do
  reinitializeGlobals
  putMsgS "*** Accelerate transform plugin ***"
  quickPrint todo
  return ([CoreDoPluginPass "Accelerate transformation" (runPass pass)] ++ todo)

runPass :: (CoreProgram -> PluginM CoreProgram) -> ModGuts -> CoreM ModGuts
runPass p guts = bindsOnlyPass
    (\x ->
      (fmap (fromKureM error) $
        runReaderT (runPluginM $ p x) (PluginEnv guts))) guts

pass :: [CoreBind] -> PluginM [CoreBind]
pass = mapM (transformBind transformExpr)


transformBind :: Monad m => (Expr CoreBndr -> m (Expr CoreBndr)) -> Bind CoreBndr -> m (Bind CoreBndr)
transformBind f (NonRec b e) = do
  e' <- f e
  return $ NonRec b e'
transformBind f (Rec bs) = do
  e' <- mapM (traverse f) bs
  return $ Rec e'

infixl 0 :$
pattern (:$) :: Expr a -> Arg a -> Expr a
pattern f :$ x = App f x

infixl 0 <:$>
(<:$>) :: Functor f => Expr a -> f (Arg a) -> f (Expr a)
f <:$> x = fmap (App f) x

infixl 0 <:*>
(<:*>) :: Applicative f => f (Expr a) -> f (Arg a) -> f (Expr a)
f <:*> x = App <$> f <*> x

-- TODO: Put each kind of transformation into its own module.
transformExpr :: Expr CoreBndr -> PluginM (Expr CoreBndr)
transformExpr = absLetFloat -- TODO: Finish implementing


-- | Perform the 'abs (let ... in x) -> let ... in abs x' transformation
-- absLetFloat :: Expr CoreBndr -> PluginM (Expr CoreBndr)
-- absLetFloat arg = do
--   absName <- thLookupId 'AccPlugin.WW.abs
--   applyR (go absName) () arg
--   where
--     go :: Var -> Rewrite () PluginM (Expr CoreBndr)
--     go absName = rewrite $ \() -> go2 absName

--     go2 :: Var -> Expr CoreBndr -> PluginM (Expr CoreBndr)
--     go2 absName expr =
--       case expr of
--         Var f :$ Let bnd x
--           | f == absName -> do
--             r <- go2 absName x
--             return $! Let bnd (Var absName :$ r)
--         _ -> fail "absLetFloat does not apply"

absLetFloat :: Expr CoreBndr -> PluginM (Expr CoreBndr)
absLetFloat expr = do
  absName <- thLookupId 'AccPlugin.WW.abs
  go absName expr
  where
    go :: Var -> Expr CoreBndr -> PluginM (Expr CoreBndr)
    go absName (Var f :$ _dict :$ _eqPrf :$ Let bnd x)
      | f == absName = do
        liftCoreM $ putMsgS "absLetFloat fired!"
        Let bnd <$> (Var absName <:$> go absName x)

    go _ e@(Var {}) = return e
    go _ e@(Lit {}) = return e
    go absName (f :$ x) = App <$> go absName f <*> go absName x
    go absName (Lam v b) = Lam v <$> (go absName b)
    go absName (Case c wild ty alts) = do
      Case <$> (go absName c)
           <*> pure wild
           <*> pure ty
           <*> (mapM (\(x, y, z) -> (x, y, ) <$> go absName z) alts)

    go absName (Let bnd x) = Let bnd <$> (go absName x)
    go absName (Tick t e) = Tick t <$> (go absName e)
    go _ e@(Type {}) = return e
    go _ e@(Coercion {}) = return e
    go absName (Cast e coer) = Cast <$> (go absName e) <*> pure coer

thLookupId :: TH.Name -> PluginM Id
thLookupId thName = do
  Just name <- liftCoreM (thNameToGhcName thName)
  lookupId name

thLookupTyCon :: TH.Name -> PluginM TyCon
thLookupTyCon thName = do
  Just name <- liftCoreM (thNameToGhcName thName)
  lookupTyCon name

-- TODO: Make a more robust solution
lookupAlt :: Bool -> [Alt CoreBndr] -> Expr CoreBndr
lookupAlt False [(_, _, a), _] = a
lookupAlt True  [_, (_, _, b)] = b
lookupAlt _ _ = error "lookupAlt: No match"

-- Adapted from HERMIT.Monad
runTcM :: TcM a -> PluginM a
runTcM m = do
    env <- getHscEnv'
    dflags <- getDynFlags
    guts <- getModGuts
    -- What is the effect of HsSrcFile (should we be using something else?)
    -- What should the boolean flag be set to?
    (msgs, mr) <- liftIO $ initTcFromModGuts env guts HsSrcFile False m
    let showMsgs (warns, errs) = showSDoc dflags $ vcat
                                                 $    text "Errors:" : pprErrMsgBagWithLoc errs
                                                   ++ text "Warnings:" : pprErrMsgBagWithLoc warns
    maybe (fail $ showMsgs msgs) return mr

buildDictionary :: Id -> PluginM (Id, [CoreBind])
buildDictionary evar = do
    runTcM $ do
#if __GLASGOW_HASKELL__ > 710
        loc <- getCtLocM (GivenOrigin UnkSkol) Nothing
#else
        loc <- getCtLoc $ GivenOrigin UnkSkol
#endif
        let predTy = varType evar
#if __GLASGOW_HASKELL__ > 710
            nonC = mkNonCanonical $ CtWanted { ctev_pred = predTy, ctev_dest = EvVarDest evar, ctev_loc = loc }
            wCs = mkSimpleWC [cc_ev nonC]
        -- TODO: Make sure solveWanteds is the right function to call.
        (_wCs', bnds) <- second evBindMapBinds <$> runTcS (solveWanteds wCs)
#else
            nonC = mkNonCanonical $ CtWanted { ctev_pred = predTy, ctev_evar = evar, ctev_loc = loc }
            wCs = mkSimpleWC [nonC]
        (_wCs', bnds) <- solveWantedsTcM wCs
#endif
        -- reportAllUnsolved _wCs' -- this is causing a panic with dictionary instantiation
                                  -- revist and fix!
        bnds1 <- initDsTc $ dsEvBinds bnds
        return (evar, bnds1)

buildDictionaryT :: Transform c PluginM Type CoreExpr
buildDictionaryT = prefixFailMsg "buildDictionaryT failed: " $ contextfreeT $ \ ty -> do
    dflags <- getDynFlags
    binder <- newIdH ("$d" ++ zEncodeString (filter (not . isSpace) (showPpr dflags ty))) ty
    (i,bnds) <- buildDictionary binder
    guardMsg (notNull bnds) "no dictionary bindings generated."
    return $ case bnds of
                [NonRec v e] | i == v -> e -- the common case that we would have gotten a single non-recursive let
                _ -> mkCoreLets bnds (varToCoreExpr i)
