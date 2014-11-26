{-# LANGUAGE ConstraintKinds    #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE TemplateHaskell    #-}
{-# LANGUAGE TypeFamilies       #-}

{-|
Module      : Application.StarTerminal.State
Description : Types representating server-state that persists across requests

The web server maintains one value of type TerminalState in a TVar.
This value records information that is to be collected by the terminal,
and includes configuration parameters.

Configuration parameters are communicated to the web server via environment variables.
The mappings of environment variables are:

  * `STAR_TERMINAL_ID`        --> _tId
  * `STAR_PUBLIC_KEY`         --> _pubkey
  * `STAR_INIT_PUBLIC_HASH`   --> _zp0
  * `STAR_INIT_INTERNAL_HASH` --> _zi0
  * `STAR_PUBLIC_SALT`        --> _z0
  * `STAR_POST_VOTE_URL`      --> _postUrl

`STAR_TERMINAL_ID` may be any string.

`STAR_PUBLIC_KEY`, `STAR_INIT_PUBLIC_HASH`, `STAR_INIT_INTERNAL_HASH`,
`STAR_PUBLIC_SALT` must be encoded strings using base-16.  The hashes and salt
must each be 256 bits.
 -}
module Application.StarTerminal.State (
  StarTerm,
  -- * The initial terminal configuration
  Terminal(Terminal), tId, pubkey, zp0, zi0, z0, postUrl, registerURL,
  -- * The running state of the terminal
  TerminalState(TerminalState), recordedVotes, ballotCodes, terminal,
  -- * AcidState actions for working with saved TerminalStates
  GetReceipt(..), GetRegisterURL(..), GetTerminalConfig(..), InsertCode(..),
  LookupBallotStyle(..), RecordVote(..), SaveReceipt(..)
  ) where

import           Control.Lens

import           Data.Acid                      (Query, Update, makeAcidic)
import qualified Data.ByteString.Lazy           as LB
import qualified Data.Map                       as M
import           Data.SafeCopy                  (base, deriveSafeCopy)
import qualified Data.Text                      as T
import           Data.Time                      (UTCTime)
import           Data.Typeable

import           Application.Star.Ballot
import           Application.Star.BallotStyle
import           Application.Star.CommonImports
import           Application.Star.HashChain
import           Application.Star.Util

type StarTerm m = (MonadError T.Text m, MonadAcidState TerminalState m, MonadSnap m)

data TerminalState = TerminalState
  {
    -- | All votes made on the terminal, kept in reverse-chronological order to
    -- make it easy to verify that each vote incorporates a hash of the
    -- previous.
    _recordedVotes :: [EncryptedRecord]
    -- | Mappings from ballot codes to ballot styles are transmitted to each
    -- terminal when voters check in at a polling place.
    -- Voters enter a code in a terminal to retrieve the appropriate ballot
    -- style.
  , _ballotCodes   :: Map BallotCode BallotStyle
  , _terminal      :: Terminal
  , _receiptInfo   :: Map BallotId (Ballot, BallotStyle, EncryptedRecord, UTCTime)
  }



-- \ Records configuration parameters that should not change while the terminal
-- is in operation.
data Terminal = Terminal
  { _tId         :: TerminalId    -- ^ unique identifier for the terminal
  , _pubkey      :: PublicKey     -- ^ issued by the election authority, used to encrypt votes
  , _zp0         :: PublicHash    -- ^ initial hash for the publicly viewable hash chain
  , _zi0         :: InternalHash  -- ^ initial hash for the non-public hash chain
  , _z0          :: LB.ByteString -- ^ public, random salt
  , _postUrl     :: String        -- ^ The terminal posts each encrypted vote to this URL
  , _registerURL :: String        -- ^ At startup, notify this URL of the terminal's existence
  } deriving Typeable

$(makeLenses ''TerminalState)
$(makeLenses ''Terminal)
$(deriveSafeCopy 0 'base ''Terminal)
$(deriveSafeCopy 0 'base ''TerminalState)

insertCode :: BallotCode -> BallotStyle -> Update TerminalState ()
insertCode code style = modify $ set (ballotCodes . at code) (Just style)

lookupBallotStyle :: BallotCode -> Query TerminalState (Maybe BallotStyle)
lookupBallotStyle code = view (ballotCodes . at code) <$> ask

recordVote :: EncryptedRecord -> Update TerminalState ()
recordVote record = modify $ over recordedVotes (record :)

saveReceipt :: BallotId -> Ballot -> BallotStyle -> EncryptedRecord -> UTCTime -> Update TerminalState ()
saveReceipt bid ballot style record t = modify $ over receiptInfo (M.insert bid (ballot, style, record, t))

-- | Retrieve the information necessary to print the human-readable ballot and receipt
getReceipt :: BallotId -> Query TerminalState (Maybe (Ballot, BallotStyle, EncryptedRecord, UTCTime))
getReceipt bid = view (receiptInfo . at bid) <$> ask

getTerminalConfig :: Query TerminalState Terminal
getTerminalConfig = view terminal <$> ask

getRegisterURL :: Query TerminalState String
getRegisterURL = view registerURL <$> getTerminalConfig

$(makeAcidic ''TerminalState [ 'getReceipt 
                             , 'getRegisterURL
                             , 'getTerminalConfig
                             , 'insertCode
                             , 'lookupBallotStyle
                             , 'recordVote
                             , 'saveReceipt
                             ])

