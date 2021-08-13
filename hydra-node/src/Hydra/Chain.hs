{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE UndecidableInstances #-}

module Hydra.Chain where

import Cardano.Prelude
import Control.Monad.Class.MonadThrow (MonadThrow)
import Data.Aeson (FromJSON, ToJSON)
import Data.Time (DiffTime)
import Hydra.Ledger (Party, Tx, Utxo)
import Hydra.Prelude (Arbitrary (arbitrary), genericArbitrary)
import Hydra.Snapshot (Snapshot)

-- | Contains the head's parameters as established in the initial transaction.
data HeadParameters = HeadParameters
  { contestationPeriod :: DiffTime
  , parties :: [Party] -- NOTE(SN): The order of this list is important for leader selection.
  }
  deriving stock (Eq, Read, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Arbitrary HeadParameters where
  arbitrary = genericArbitrary

type ContestationPeriod = DiffTime

-- | Data type used to post transactions on chain. It holds everything to
-- construct corresponding Head protocol transactions.
data PostChainTx tx
  = InitTx HeadParameters
  | CommitTx Party (Utxo tx)
  | AbortTx (Utxo tx)
  | CollectComTx (Utxo tx)
  | CloseTx (Snapshot tx)
  | ContestTx (Snapshot tx)
  | FanoutTx (Utxo tx)
  deriving stock (Generic)

deriving instance Tx tx => Eq (PostChainTx tx)
deriving instance Tx tx => Show (PostChainTx tx)
deriving instance Tx tx => Read (PostChainTx tx)
deriving instance Tx tx => ToJSON (PostChainTx tx)
deriving instance Tx tx => FromJSON (PostChainTx tx)

instance (Arbitrary tx, Arbitrary (Utxo tx)) => Arbitrary (PostChainTx tx) where
  arbitrary = genericArbitrary

-- REVIEW(SN): There is a similarly named type in plutus-ledger, so we might
-- want to rename this
-- TODO(SN): incomplete
-- | Describes transactions as seen on chain. Holds as minimal information as
-- possible to simplify observing the chain.
data OnChainTx
  = OnInitTx HeadParameters
  | OnCommitTx
  | OnAbortTx
  | OnCollectComTx
  | OnCloseTx
  | OnContestTx
  | OnFanoutTx
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

instance Arbitrary OnChainTx where
  arbitrary = genericArbitrary

data ChainError = ChainError
  deriving (Exception, Show)

-- | Handle to interface with the main chain network
newtype Chain tx m = Chain
  { -- | Construct and send a transaction to the main chain corresponding to the
    -- given 'OnChainTx' event.
    -- Does at least throw 'ChainError'.
    postTx :: MonadThrow m => PostChainTx tx -> m ()
  }

-- | Handle to interface observed transactions.
type ChainCallback m = OnChainTx -> m ()

-- | A type tying both posting and observing transactions into a single /Component/.
type ChainComponent tx m a = ChainCallback m -> (Chain tx m -> m a) -> m a