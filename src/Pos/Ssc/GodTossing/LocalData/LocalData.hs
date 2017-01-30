{-# LANGUAGE AllowAmbiguousTypes  #-}
{-# LANGUAGE Rank2Types           #-}
{-# LANGUAGE TypeFamilies         #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -fno-warn-redundant-constraints #-}

-- | This module defines methods which operate on GtLocalData.

module Pos.Ssc.GodTossing.LocalData.LocalData
       (
         localOnNewSlot
       , sscIsDataUseful
       , sscProcessMessage
       , getLocalPayload
         -- * Instances
         -- ** instance SscLocalDataClass SscGodTossing
       ) where

import           Control.Lens                         (Getter, at, to, (%=), (.=))
import           Control.Monad.Except                 (MonadError (throwError),
                                                       runExceptT)
import           Control.Monad.State                  (get)
import           Data.Containers                      (ContainerKey,
                                                       SetContainer (notMember))
import qualified Data.HashMap.Strict                  as HM
import qualified Data.HashSet                         as HS
import           Data.List.NonEmpty                   (NonEmpty ((:|)))
import           Serokell.Util.Verify                 (isVerSuccess)
import           Universum

import           Pos.Binary.Ssc                       ()
import           Pos.Lrc.Types                        (Richmen, RichmenSet)
import           Pos.Slotting                         (getCurrentSlot)
import           Pos.Ssc.Class.LocalData              (LocalQuery, LocalUpdate,
                                                       SscLocalDataClass (..))
import           Pos.Ssc.Extra.MonadLD                (MonadSscLD)
import           Pos.Ssc.GodTossing.Core              (CommitmentsMap (getCommitmentsMap),
                                                       GtPayload (..), InnerSharesMap,
                                                       Opening, SignedCommitment,
                                                       VssCertificate (vcSigningKey, vcVssKey),
                                                       checkCertTTL, checkCommShares,
                                                       checkShare, checkShares,
                                                       diffCommMap, getCertId,
                                                       insertSignedCommitment,
                                                       intersectCommMapWith,
                                                       isCommitmentIdx, isOpeningIdx,
                                                       isSharesIdx, vcExpiryEpoch,
                                                       verifySignedCommitment)
import           Pos.Ssc.GodTossing.Functions         (computeParticipants,
                                                       getStableCertsPure)
import           Pos.Ssc.GodTossing.LocalData.Helpers (GtState, gtGlobalCertificates,
                                                       gtGlobalCommitments,
                                                       gtGlobalOpenings, gtGlobalShares,
                                                       gtLastProcessedSlot,
                                                       gtLocalCertificates,
                                                       gtLocalCommitments,
                                                       gtLocalOpenings, gtLocalShares,
                                                       gtRunModify, gtRunRead)
import           Pos.Ssc.GodTossing.LocalData.Types   (GtLocalData (..), ldCertificates,
                                                       ldCommitments, ldLastProcessedSlot,
                                                       ldOpenings, ldShares)
import           Pos.Ssc.GodTossing.Toss              (TossVerErrorTag (..),
                                                       TossVerFailure (..),
                                                       checkOpeningMatchesCommitment)
import           Pos.Ssc.GodTossing.Type              (SscGodTossing)
import           Pos.Ssc.GodTossing.Types             (GtGlobalState, _gsCommitments,
                                                       _gsOpenings, _gsShares,
                                                       _gsVssCertificates)
import           Pos.Ssc.GodTossing.Types.Message     (GtMsgContents (..), GtMsgTag (..))
import qualified Pos.Ssc.GodTossing.VssCertData       as VCD
import           Pos.Types                            (EpochIndex, SlotId (..),
                                                       StakeholderId, addressHash)

instance SscLocalDataClass SscGodTossing where
    sscGetLocalPayloadQ = getLocalPayload
    sscApplyGlobalStateU = applyGlobal
    sscNewLocalData =
        GtLocalData mempty mempty mempty VCD.empty <$> getCurrentSlot

type LDQuery a = forall m .  MonadReader GtState m => m a
type LDUpdate a = forall m . MonadState GtState m  => m a
type LDProcess a = forall m . ( MonadError TossVerFailure m
                              , MonadState GtState m)  => m a

----------------------------------------------------------------------------
-- Apply Global State
----------------------------------------------------------------------------

applyGlobal :: Richmen -> GtGlobalState -> LocalUpdate SscGodTossing ()
applyGlobal richmen globalData = do
    let globalCerts = VCD.certs . _gsVssCertificates $ globalData
        participants = computeParticipants richmen globalCerts
        globalCommitments = _gsCommitments globalData
        -- globalComms = getCommitmentsMap globalCommitments
        globalOpenings = _gsOpenings globalData
        globalShares = _gsShares globalData
        intersectWithPs = intersectCommMapWith identity
    let filterCommitments comms =
            foldl' (&) comms $
            [
            -- Remove commitments which are contained already in global state
              (`diffCommMap` globalCommitments)
            -- Remove commitments which corresponds to expired certs
            , (`intersectWithPs` participants)
            ]
    let filterOpenings opens =
            foldl' (&) opens $
            [ (`HM.difference` globalOpenings)
            , (`HM.intersection` getCommitmentsMap globalCommitments)
            -- Select opening which corresponds its commitment
            , HM.filterWithKey
                  (curry $ checkOpeningMatchesCommitment globalCommitments)
            ]
    let checkCorrectShares pkTo shares = HM.filterWithKey
            (\pkFrom share ->
                 checkShare
                     globalCommitments
                     globalOpenings
                     globalCerts
                     (pkTo, pkFrom, share)) shares
    let filterShares shares =
            foldl' (&) shares $
            [ (`HM.difference` globalShares)
            , (`HM.intersection` participants)
            -- Select shares to nodes which sent commitments
            , map (`HM.intersection` getCommitmentsMap globalCommitments)
            -- Ensure that share sent from pkFrom to pkTo is valid
            , HM.mapWithKey checkCorrectShares
            ]
    ldCommitments  %= filterCommitments
    ldOpenings  %= filterOpenings
    ldShares  %= filterShares
    ldCertificates  %= (`VCD.difference` globalCerts)

----------------------------------------------------------------------------
-- Get Local Payload
----------------------------------------------------------------------------

getLocalPayload :: LocalQuery SscGodTossing (SlotId, GtPayload)
getLocalPayload = do
    s <- view ldLastProcessedSlot
    (s, ) <$> (getPayload (siSlot s) <*> (VCD.certs <$> view ldCertificates))
  where
    getPayload slotIdx
        | isCommitmentIdx slotIdx =
              CommitmentsPayload <$> view ldCommitments
        | isOpeningIdx slotIdx = OpeningsPayload <$> view ldOpenings
        | isSharesIdx slotIdx = SharesPayload <$> view ldShares
        | otherwise = pure CertificatesPayload

----------------------------------------------------------------------------
-- Process New Slot
----------------------------------------------------------------------------

-- | Clean-up some data when new slot starts.
localOnNewSlot
    :: MonadSscLD SscGodTossing m
    => RichmenSet -> SlotId -> m ()
localOnNewSlot richmen = gtRunModify . localOnNewSlotU richmen

localOnNewSlotU :: RichmenSet -> SlotId -> LDUpdate ()
localOnNewSlotU richmen si@SlotId {siSlot = slotIdx, siEpoch = epochIdx} = do
    lastSlot <- use gtLastProcessedSlot
    if siEpoch lastSlot /= epochIdx
      then do
        gtLocalCommitments .= mempty
        gtLocalOpenings .= mempty
        gtLocalShares .= mempty
      else do
        unless (isCommitmentIdx slotIdx) $ gtLocalCommitments .= mempty
        unless (isOpeningIdx slotIdx) $ gtLocalOpenings .= mempty
        unless (isSharesIdx slotIdx) $ gtLocalShares .= mempty
    gtLocalCertificates %= VCD.setLastKnownSlot si
    gtLocalCertificates %= VCD.filter (`HS.member` richmen)
    gtLastProcessedSlot .= si

----------------------------------------------------------------------------
-- Check knowledge of data
----------------------------------------------------------------------------

-- CHECK: @sscIsDataUseful
-- #sscIsDataUsefulQ

-- | Check whether SSC data with given tag and public key can be added
-- to local data.
sscIsDataUseful
    :: MonadSscLD SscGodTossing m
    => GtMsgTag -> StakeholderId -> m Bool
sscIsDataUseful tag = gtRunRead . sscIsDataUsefulQ tag

-- CHECK: @sscIsDataUsefulQ
-- | Check whether SSC data with given tag and public key can be added
-- to local data.
sscIsDataUsefulQ :: GtMsgTag -> StakeholderId -> LDQuery Bool
sscIsDataUsefulQ CommitmentMsg =
    sscIsDataUsefulImpl
        (gtLocalCommitments . to getCommitmentsMap)
        (gtGlobalCommitments . to getCommitmentsMap)
sscIsDataUsefulQ OpeningMsg =
    sscIsDataUsefulSetImpl gtLocalOpenings gtGlobalOpenings
sscIsDataUsefulQ SharesMsg =
    sscIsDataUsefulSetImpl gtLocalShares gtGlobalShares
sscIsDataUsefulQ VssCertificateMsg = sscIsCertUsefulImpl
  where
    sscIsCertUsefulImpl addr = do
        loc <- VCD.certs <$> view gtLocalCertificates
        glob <- VCD.certs <$> view gtGlobalCertificates
        return $ (not $ addr `HM.member` loc) && (not $ addr `HM.member` glob)

type MapGetter a = Getter GtState (HashMap StakeholderId a)
type SetGetter set = Getter GtState set

sscIsDataUsefulImpl :: MapGetter a
                    -> MapGetter a
                    -> StakeholderId
                    -> LDQuery Bool
sscIsDataUsefulImpl localG globalG addr =
    andM [ notMember addr <$> view globalG
         , notMember addr <$> view localG ]

sscIsDataUsefulSetImpl
    :: (SetContainer set, ContainerKey set ~ StakeholderId)
    => MapGetter a -> SetGetter set -> StakeholderId -> LDQuery Bool
sscIsDataUsefulSetImpl localG globalG addr =
    andM [ notMember addr <$> view localG
         , notMember addr <$> view globalG ]

----------------------------------------------------------------------------
-- Ssc Process Message
----------------------------------------------------------------------------

-- | Process message and save it if needed. Result is whether message
-- has been actually added.
sscProcessMessage ::
       (MonadSscLD SscGodTossing m)
    => (EpochIndex, Richmen) -> GtMsgContents -> m (Either TossVerFailure ())
sscProcessMessage richmen msg =
    gtRunModify $ runExceptT $
    sscProcessMessageU (second (HS.fromList . toList) richmen) msg

sscProcessMessageU
    :: (EpochIndex, RichmenSet)
    -> GtMsgContents
    -> LDProcess ()
sscProcessMessageU (richmenEpoch, richmen) msg = do
    epochIdx <- siEpoch <$> use gtLastProcessedSlot
    when (epochIdx /= richmenEpoch) $
           throwError $ DifferentEpoches richmenEpoch epochIdx
    case msg of
        MCCommitment     comm -> processCommitment richmen comm
        MCOpening id open     -> processOpening id open
        MCShares  id shares   -> processShares richmen id shares
        MCVssCertificate cert -> processVssCertificate richmen cert

runChecks :: MonadError TossVerFailure m => [(m Bool, TossVerFailure)] -> m ()
runChecks checks =
    whenJustM (findFalseM checks) $ throwError . snd
  where
    -- mmm, velosipedik
    findFalseM []     = pure Nothing
    findFalseM (x:xs) = ifM (fst x) (findFalseM xs) (pure $ Just x)

-- | Convert (ReaderT s) to any (MonadState s)
readerTToState
    :: MonadState s m
    => ReaderT s m a -> m a
readerTToState rdr = get >>= runReaderT rdr

processCommitment
    :: RichmenSet
    -> SignedCommitment
    -> LDProcess ()
processCommitment richmen c = do
    epochIdx <- siEpoch <$> use gtLastProcessedSlot
    stableCerts <- getStableCertsPure epochIdx <$> use gtGlobalCertificates
    let participants = stableCerts `HM.intersection` HS.toMap richmen
    let vssPublicKeys = map vcVssKey $ toList participants
    let checks epochIndex =
            [ (not . HM.member id . getCommitmentsMap <$> view gtGlobalCommitments
              , tossEx CommitmentAlreadySent)
            , (not . HM.member id . getCommitmentsMap <$> view gtLocalCommitments
              , tossEx CommitmentAlreadySent)
            , (pure $ id `HM.member` participants
              , tossEx CommitingNoParticipants)
            , (pure . isVerSuccess $ verifySignedCommitment epochIndex c
              , tossEx CommitmentInvalid)
            , (pure $ checkCommShares vssPublicKeys c
              , tossEx CommSharesOnWrongParticipants)
            ]
    readerTToState $ runChecks $ checks epochIdx
    gtLocalCommitments %= insertSignedCommitment c
  where
    id = addressHash $ view _1 c
    tossEx = flip TossVerFailure (id:|[])

processOpening :: StakeholderId -> Opening -> LDProcess ()
processOpening id o = do
    readerTToState $ runChecks checks
    gtLocalOpenings %= HM.insert id o
  where
    tossEx = flip TossVerFailure (id:|[])
    checks = [ (checkAbsence id, tossEx OpeningAlreadySent)
             , (matchOpening id o, tossEx OpeningNotMatchCommitment)
             ]

    checkAbsence = sscIsDataUsefulSetImpl gtLocalOpenings gtGlobalOpenings
    -- Match opening to commitment from globalCommitments
    matchOpening sid opening =
        flip checkOpeningMatchesCommitment (sid, opening) <$> view gtGlobalCommitments

-- CHECK: #checkShares
processShares :: RichmenSet -> StakeholderId -> InnerSharesMap -> LDProcess ()
processShares richmen id s = do
    epochIdx <- siEpoch <$> use gtLastProcessedSlot
    stableCerts <- getStableCertsPure epochIdx <$> use gtGlobalCertificates
    let checks =
          [ (pure $ not (id `HS.member` richmen), tossEx SharesNotRichmen)
          , (sscIsDataUsefulQ SharesMsg id, tossEx SharesAlreadySent)
          , (checkSharesDo stableCerts s, tossEx DecrSharesNotMatchCommitment)
          ]
    readerTToState $ runChecks checks
    gtLocalShares . at id .= Just s
  where
    tossEx = flip TossVerFailure (id:|[])
    checkSharesDo certs shares = do
        comms    <- view gtGlobalCommitments
        openings <- view gtGlobalOpenings
        pure (checkShares comms openings certs id shares)

processVssCertificate :: RichmenSet
                      -> VssCertificate
                      -> LDProcess ()
processVssCertificate richmen c = do
    lpe <- siEpoch <$> use gtLastProcessedSlot
    let checks =
          [ ( pure $ (addressHash $ vcSigningKey c) `HS.member` richmen,
              tossEx CertificateNotRichmen)
          , ( pure $ checkCertTTL lpe c, CertificateInvalidTTL certSingleton)
          , ( sscIsDataUsefulQ VssCertificateMsg id, tossEx CertificateAlreadySent)
          ]
    readerTToState $ runChecks checks
    gtLocalCertificates %= VCD.insert c
  where
    id = getCertId c
    certSingleton = (c, vcExpiryEpoch c):|[]
    tossEx = flip TossVerFailure (id:|[])
