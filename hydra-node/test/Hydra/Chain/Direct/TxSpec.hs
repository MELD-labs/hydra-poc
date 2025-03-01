{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -Wno-incomplete-uni-patterns #-}

-- | Unit tests for our "hand-rolled" transactions as they are used in the
-- "direct" chain component.
module Hydra.Chain.Direct.TxSpec where

import Hydra.Prelude hiding (label)
import Test.Hydra.Prelude

import Hydra.Chain.Direct.Tx

import Cardano.Binary (serialize)
import Cardano.Ledger.Alonzo (TxOut)
import Cardano.Ledger.Alonzo.Data (Data (Data), hashData)
import Cardano.Ledger.Alonzo.Language (Language (PlutusV1))
import Cardano.Ledger.Alonzo.PParams (PParams, PParams' (..))
import Cardano.Ledger.Alonzo.Scripts (ExUnits (..), txscriptfee)
import Cardano.Ledger.Alonzo.Tools (ScriptFailure, evaluateTransactionExecutionUnits)
import Cardano.Ledger.Alonzo.Tx (ValidatedTx (ValidatedTx, body, wits), outputs, txfee, txrdmrs)
import Cardano.Ledger.Alonzo.TxBody (TxOut (TxOut))
import Cardano.Ledger.Alonzo.TxWitness (
  RdmrPtr,
  TxWitness (txdats),
  unRedeemers,
  unTxDats,
 )
import Cardano.Ledger.Crypto (StandardCrypto)
import Cardano.Ledger.Mary.Value (AssetName, PolicyID, Value (Value))
import qualified Cardano.Ledger.SafeHash as SafeHash
import Cardano.Ledger.Shelley.API (Coin (Coin), StrictMaybe (SJust, SNothing), TxId (TxId), TxIn (TxIn), UTxO (UTxO))
import Cardano.Ledger.Slot (EpochSize (EpochSize))
import Cardano.Ledger.Val (inject)
import Cardano.Slotting.EpochInfo (fixedEpochInfo)
import Cardano.Slotting.Time (SystemStart (..), mkSlotLength)
import Data.Array (array)
import qualified Data.ByteString.Lazy as LBS
import Data.List (nub, (\\))
import qualified Data.Map as Map
import Data.Maybe (fromJust)
import qualified Data.Sequence.Strict as Seq
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Hydra.Chain (HeadParameters (..), OnChainTx (..), PostChainTx (..))
import Hydra.Chain.Direct.Fixture (maxTxSize, pparams)
import Hydra.Chain.Direct.Util (Era)
import Hydra.Chain.Direct.Wallet (ErrCoverFee (..), coverFee_)
import qualified Hydra.Contract.Head as Head
import qualified Hydra.Contract.MockInitial as MockInitial
import Hydra.Data.ContestationPeriod (contestationPeriodFromDiffTime)
import Hydra.Data.Party (partyFromVerKey)
import Hydra.Ledger (Utxo)
import Hydra.Ledger.Simple (SimpleTx)
import Hydra.Party (vkey)
import Ledger.Value (currencyMPSHash, unAssetClass)
import Plutus.V1.Ledger.Api (PubKeyHash, toBuiltinData, toData)
import Test.Cardano.Ledger.Alonzo.PlutusScripts (defaultCostModel)
import Test.Cardano.Ledger.Alonzo.Serialisation.Generators ()
import Test.QuickCheck (NonEmptyList (NonEmpty), counterexample, elements, forAll, label, property, withMaxSuccess, (.&&.), (===))
import Test.QuickCheck.Instances ()

spec :: Spec
spec =
  parallel $ do
    describe "initTx" $ do
      prop "is observed" $ \txIn cperiod (party :| parties) cardanoKeys ->
        let params = HeadParameters cperiod (party : parties)
            tx = initTx cardanoKeys params txIn
            observed = observeInitTx @SimpleTx party tx
         in case observed of
              Just (octx, _) -> octx === OnInitTx cperiod (party : parties)
              _ -> property False
              & counterexample ("Observed: " <> show observed)

      prop "is not observed if not invited" $ \txIn cperiod (NonEmpty parties) cardanoKeys ->
        forAll (elements parties) $ \notInvited ->
          let invited = nub parties \\ [notInvited]
              tx = initTx cardanoKeys (HeadParameters cperiod invited) txIn
           in isNothing (observeInitTx notInvited tx)
                & counterexample ("observing as: " <> show notInvited)
                & counterexample ("invited: " <> show invited)

      prop "updates on-chain state to 'Initial'" $ \txIn cperiod (me :| others) ->
        let params = HeadParameters cperiod parties
            parties = fst <$> me : others
            cardanoKeys = snd <$> me : others
            tx = initTx cardanoKeys params txIn
            res = observeInitTx @SimpleTx (fst me) tx
         in case res of
              Just (_, Initial{initials, threadOutput = (_txin, _txout, tt, ps)}) ->
                tt === threadToken
                  .&&. ps === params
                  .&&. length initials === length cardanoKeys
              _ -> property False
              & counterexample ("Result: " <> show res)
              & counterexample ("Tx: " <> show tx)

    describe "commitTx" $ do
      prop ("transaction size below limit (" <> show maxTxSize <> ")") $
        \party (utxo :: Utxo SimpleTx) initialIn ->
          let tx = commitTx @SimpleTx party utxo initialIn
              cbor = serialize tx
              len = LBS.length cbor
           in len < maxTxSize
                & label (show (len `div` 1024) <> "kB")
                & counterexample ("Tx: " <> show tx)
                & counterexample ("Tx serialized size: " <> show len)

      prop "is observed" $
        \party (utxo :: Utxo SimpleTx) initialIn ->
          let tx = commitTx @SimpleTx party utxo initialIn
           in observeCommitTx @SimpleTx tx
                === Just OnCommitTx{party, committed = utxo}
                & counterexample ("Tx: " <> show tx)

    describe "abortTx" $ do
      -- NOTE(AB): This property fails if the list generated is arbitrarily long
      prop ("transaction size below limit (" <> show maxTxSize <> ")") $ \txIn params initials ->
        let tx = abortTx (txIn, threadToken, params) (take 10 initials)
            cbor = serialize tx
            len = LBS.length cbor
         in len < maxTxSize
              & label (show (len `div` 1024) <> "kB")
              & counterexample ("Tx: " <> show tx)
              & counterexample ("Tx serialized size: " <> show len)

      prop "updates on-chain state to 'Final'" $ \txIn params (NonEmpty initials) ->
        let txOut = TxOut headAddress headValue SNothing -- not covered by this test
            headAddress = scriptAddr $ plutusScript $ Head.validatorScript policyId
            headValue = inject (Coin 2_000_000)
            utxo = Map.singleton txIn txOut
            tx = abortTx (txIn, threadToken, params) initials
            res = observeAbortTx @SimpleTx utxo tx
         in case res of
              Just (_, st) -> st === Final
              _ -> property False
              & counterexample ("Result: " <> show res)
              & counterexample ("Tx: " <> show tx)

      -- TODO(SN): this requires the abortTx to include a redeemer, for a TxIn,
      -- spending a Head-validated output
      prop "validates against 'head' script in haskell (unlimited budget)" $
        withMaxSuccess 30 $ \txIn params@HeadParameters{contestationPeriod, parties} (NonEmpty initials) ->
          let tx = abortTx (txIn, threadToken, params) initials
              -- TODO(SN): DRY
              -- input governed by head script
              -- datum : Initial + head parameters
              -- redeemer : State
              txOut = TxOut headAddress headValue (SJust headDatumHash)
              (policy, _) = first currencyMPSHash (unAssetClass threadToken)
              headAddress = scriptAddr $ plutusScript $ Head.validatorScript policy
              headValue = inject (Coin 2_000_000)
              headDatumHash =
                hashData @Era . Data $
                  toData $
                    Head.Initial
                      (contestationPeriodFromDiffTime contestationPeriod)
                      (map (partyFromVerKey . vkey) parties)

              utxo = UTxO $ Map.fromList $ (txIn, txOut) : map mkMockInitialTxOut initials

              results = validateTxScriptsUnlimited utxo tx
           in 1 + length initials == length (rights $ Map.elems results)
                & counterexample ("Evaluation results: " <> show results)
                & counterexample ("Tx: " <> show tx)
                & counterexample ("Input utxo: " <> show utxo)

      prop "cover fee correctly handles redeemers" $
        withMaxSuccess 60 $ \txIn walletUtxo params (NonEmpty initials) cardanoKeys ->
          let ValidatedTx{body = initTxBody} = initTx cardanoKeys params txIn
              txInitIn = TxIn (TxId $ SafeHash.hashAnnotated initTxBody) 0
              -- FIXME(AB): fromJust is partial
              txInitOut = fromJust $ Seq.lookup 0 (outputs initTxBody)
              txAbort = abortTx (txInitIn, threadToken, params) initials
              lookupUtxo = Map.fromList ((txInitIn, txInitOut) : map mkMockInitialTxOut initials)
              utxo = UTxO $ walletUtxo <> lookupUtxo
           in case coverFee_ pparams lookupUtxo walletUtxo txAbort of
                Left err ->
                  True
                    & label
                      ( case err of
                          ErrNoAvailableUtxo -> "No available Utxo"
                          ErrNotEnoughFunds{} -> "Not enough funds"
                          ErrUnknownInput{} -> "Unknown input"
                      )
                Right (_, txAbortWithFees@ValidatedTx{body = abortTxBody}) ->
                  let actualExecutionCost = executionCost pparams txAbortWithFees
                   in actualExecutionCost > Coin 0 && txfee abortTxBody > actualExecutionCost
                        & label "Ok"
                        & counterexample ("Execution cost: " <> show actualExecutionCost)
                        & counterexample ("Fee: " <> show (txfee abortTxBody))
                        & counterexample ("Tx: " <> show txAbortWithFees)
                        & counterexample ("Input utxo: " <> show utxo)

executionCost :: PParams Era -> ValidatedTx Era -> Coin
executionCost PParams{_prices} ValidatedTx{wits} =
  txscriptfee _prices executionUnits
 where
  executionUnits = foldMap snd $ unRedeemers $ txrdmrs wits

mkMockInitialTxOut :: (TxIn StandardCrypto, PubKeyHash) -> (TxIn StandardCrypto, TxOut Era)
mkMockInitialTxOut (txIn, pkh) =
  (txIn, TxOut initialAddress initialValue (SJust initialDatumHash))
 where
  initialAddress = scriptAddr $ plutusScript MockInitial.validatorScript
  initialValue = inject (Coin 0)
  initialDatumHash =
    hashData @Era $ Data $ toData $ MockInitial.datum pkh

isImplemented :: PostChainTx tx -> OnChainHeadState -> Bool
isImplemented tx st =
  case (tx, st) of
    (InitTx{}, Closed) -> True
    (AbortTx{}, Initial{}) -> True
    _ -> False

-- | Evaluate all plutus scripts and return execution budgets of a given
-- transaction (any included budgets are ignored).
validateTxScriptsUnlimited ::
  -- | Utxo set used to create context for any tx inputs.
  UTxO Era ->
  ValidatedTx Era ->
  Map RdmrPtr (Either (ScriptFailure StandardCrypto) ExUnits)
validateTxScriptsUnlimited utxo tx =
  runIdentity $ evaluateTransactionExecutionUnits pparams tx utxo epochInfo systemStart costmodels
 where
  -- REVIEW(SN): taken from 'testGlobals'
  epochInfo = fixedEpochInfo (EpochSize 100) (mkSlotLength 1)
  -- REVIEW(SN): taken from 'testGlobals'
  systemStart = SystemStart $ posixSecondsToUTCTime 0
  -- NOTE(SN): copied from Test.Cardano.Ledger.Alonzo.Tools as not exported
  costmodels = array (PlutusV1, PlutusV1) [(PlutusV1, fromJust defaultCostModel)]

-- | Extract NFT candidates. any single quantity assets not being ADA is a
-- candidate.
txOutNFT :: TxOut Era -> [(PolicyID StandardCrypto, AssetName)]
txOutNFT (TxOut _ value _) =
  mapMaybe findUnitAssets $ Map.toList assets
 where
  (Value _ assets) = value

  findUnitAssets (policy, as) = do
    (name, _q) <- find unitQuantity $ Map.toList as
    pure (policy, name)

  unitQuantity (_name, q) = q == 1
