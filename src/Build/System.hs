{-# LANGUAGE FlexibleContexts, ScopedTypeVariables #-}
module Build.System (busy, memo, make, excel, shake, cloudShake, bazel) where

import Control.Monad.State

import Build
import Build.Algorithm
import Build.Store
import Build.Trace

busy :: forall k v. Eq k => Build Monad () k v
busy task key store = execState (fetch key) store
  where
    fetch :: k -> State (Store () k v) v
    fetch k = case task fetch k of
        Nothing  -> gets (getValue k)
        Just act -> do v <- act; modify (putValue k v); return v

memo :: Eq k => Build Monad () k v
memo = recursive $ \key _fetch act -> do
    (value, _deps) <- act
    modify $ \(store, t) -> (putValue key value store, t)

------------------------------------- Make -------------------------------------
type Time = Integer
type MakeInfo k = (k -> Time, Time)

make :: forall k v. Ord k => Build Applicative (MakeInfo k) k v
make = topological process
  where
    process :: k -> [k] -> State (Store (MakeInfo k) k v) v -> State (Store (MakeInfo k) k v) ()
    process key deps act = do
        (modTime, now) <- gets getInfo
        let dirty = or [ modTime dep > modTime key | dep <- deps ]
        when dirty $ do
            v <- act
            let newModTime k = if k == key then now else modTime k
            modify $ putInfo (newModTime, now + 1) . putValue key v

------------------------------------- Excel ------------------------------------
data DependencyApproximation k = SubsetOf [k] | Unknown -- Add Exact [k]?

type ExcelInfo k = ((k -> Bool, k -> DependencyApproximation k), CalcChain k)

excel :: Ord k => Build Monad (ExcelInfo k) k v
excel = reordering process
  where
    process key act = do
        (dirty, deps) <- gets getInfo
        let rebuild = dirty key || case deps key of SubsetOf ks -> any dirty ks
                                                    Unknown     -> True
        if not rebuild
            then return Nothing
            else do
                result <- act
                case result of
                    MissingDependency _ -> return ()
                    Result v _dynamicDependencies -> do
                        let newDirty k = if k == key then True else dirty k
                        modify $ putInfo (newDirty, deps) . putValue key v
                return (Just result)

------------------------------------- Shake ------------------------------------
shake :: (Eq k, Hashable v) => Build Monad (VT k v) k v
shake = recursive $ \key fetch act -> do
    vt <- gets (getInfo . fst)
    dirty <- not <$> verifyVT (fmap hash . fetch) key vt
    when dirty $ do
        (value, deps) <- act
        modify $ \(s, t) ->
            let newS = putValue key value s
            in (updateInfo (recordVT newS key deps) newS, t)

---------------------------------- Cloud Shake ---------------------------------
cloudShake :: (Eq k, Hashable v) => Build Monad (CT k v) k v
cloudShake = recursive $ \key fetch act -> do
    ct <- gets (getInfo . fst)
    dirty <- not <$> verifyCT (fmap hash . fetch) key ct
    when dirty $ do
        maybeValue <- constructCT (fmap hash . fetch) key ct
        case maybeValue of
            Just value -> modify $ \(s, t) -> (putValue key value s, t)
            Nothing -> do
                (value, deps) <- act
                modify $ \(s, t) ->
                    let newS = putValue key value s
                    in (updateInfo (recordCT newS key deps) newS, t)

------------------------------------- Bazel ------------------------------------
bazel :: (Ord k, Hashable v) => Build Applicative (CT k v) k v
bazel = topological $ \key deps act -> do
    ct <- gets getInfo
    store <- get
    dirty <- not <$> verifyCT (\k -> return $ getHash k store) key ct
    when dirty $ do
        maybeValue <- constructCT (\k -> return $ getHash k store) key ct
        case maybeValue of
            Just value -> modify (putValue key value)
            Nothing -> do
                value <- act
                modify $ \s ->
                    let newS = putValue key value s
                    in updateInfo (recordCT newS key deps) newS