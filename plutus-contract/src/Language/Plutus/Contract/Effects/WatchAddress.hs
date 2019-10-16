{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds     #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE DerivingStrategies  #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE MonoLocalBinds      #-}
{-# LANGUAGE OverloadedLabels    #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeOperators       #-}
module Language.Plutus.Contract.Effects.WatchAddress where

import           Control.Lens                               (at, (^.))
import           Data.Aeson                                 (FromJSON, ToJSON)
import           Data.Map                                   (Map)
import qualified Data.Map                                   as Map
import           Data.Maybe                                 (fromMaybe)
import           Data.Row
import           Data.Set                                   (Set)
import qualified Data.Set                                   as Set
import           GHC.Generics                               (Generic)
import           Ledger                                     (Address, Slot, TxId, Value, hashTx)
import           Ledger.AddressMap                          (AddressMap)
import qualified Ledger.AddressMap                          as AM
import           Ledger.Tx                                  (Tx)
import qualified Ledger.Value                               as V

import           Language.Plutus.Contract.Effects.AwaitSlot
import           Language.Plutus.Contract.Request           (Contract, ContractRow, requestMaybe)
import           Language.Plutus.Contract.Schema            (Event (..), Handlers (..), Input, Output)
import           Language.Plutus.Contract.Util              (loopM)

type AddressSymbol = "address"

type HasWatchAddress s =
    ( HasType AddressSymbol (Address, Tx) (Input s)
    , HasType AddressSymbol (Set Address) (Output s)
    , ContractRow s)

type WatchAddress = AddressSymbol .== ((Address, Tx), Set Address)

newtype InterestingAddresses =
    InterestingAddresses  { unInterestingAddresses :: Set Address }
        deriving stock (Eq, Ord, Generic, Show)
        deriving newtype (Semigroup, Monoid, ToJSON, FromJSON)

-- | Wait for the next transaction that changes an address.
nextTransactionAt :: forall s. HasWatchAddress s => Address -> Contract s Tx
nextTransactionAt addr =
    let s = Set.singleton addr
        check :: (Address, Tx) -> Maybe Tx
        check (addr', tx) = if addr == addr' then Just tx else Nothing
    in
    requestMaybe @AddressSymbol @_ @_ @s s check

-- | Watch an address until the given slot, then return all known outputs
--   at the address.
watchAddressUntil
    :: forall s.
       ( HasAwaitSlot s
       , HasWatchAddress s
       )
    => Address
    -> Slot
    -> Contract s AddressMap
watchAddressUntil a = collectUntil @s AM.updateAddresses (AM.addAddress a mempty) (nextTransactionAt @s a)

-- | Watch an address for changes, and return the outputs
--   at that address when the total value at the address
--   has surpassed the given value.
fundsAtAddressGt
    :: forall s.
       HasWatchAddress s
    => Address
    -> Value
    -> Contract s AddressMap
fundsAtAddressGt addr' vl = loopM go mempty where
    go cur = do
        delta <- AM.fromTxOutputs <$> nextTransactionAt @s addr'
        let cur' = cur <> delta
            presentVal = fromMaybe mempty (AM.values cur' ^. at addr')
        if presentVal `V.gt` vl
        then pure (Right cur') else pure (Left cur')

-- | Watch the address until the transaction with the given 'TxId' appears
--   on the ledger. Warning: If the transaction does not touch the address,
--   or is invalid, then 'awaitTransactionConfirmed' will not return.
awaitTransactionConfirmed
    :: forall s.
       ( HasWatchAddress s )
    => Address
    -> TxId
    -> Contract s Tx
awaitTransactionConfirmed addr txid =
    flip loopM () $ \_ -> do
        tx' <- nextTransactionAt addr
        if hashTx tx' == txid
        then pure $ Right tx'
        else pure $ Left ()

events
    :: forall s.
       ( HasType AddressSymbol (Address, Tx) (Input s)
       , AllUniqueLabels (Input s)
       )
    => AddressMap
    -> Tx
    -> Map Address (Event s)
events utxo tx =
    Map.fromSet
        (\addr -> Event $ IsJust (Label @AddressSymbol) (addr, tx))
        (AM.addressesTouched utxo tx)

addresses
    :: forall s.
    ( HasType AddressSymbol (Set Address) (Output s))
    => Handlers s
    -> Set Address
addresses (Handlers r) = r .! Label @AddressSymbol