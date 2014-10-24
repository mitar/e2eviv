{-# LANGUAGE FlexibleContexts, OverloadedStrings, Rank2Types, TemplateHaskell #-}
module Application.Star.Controller where

import Application.Star.Ballot
import Application.Star.BallotStyle
import Application.Star.HashChain
import Application.Star.ID
import Application.Star.SerializableBS
import Application.Star.Util
import Application.Star.CommonImports hiding (method)
import Control.Arrow
import Control.Lens
import Data.Char
import System.Random

import qualified Control.Concurrent.STM as STM
import qualified Data.Map  as M
import qualified Data.Set  as S
import qualified Data.Text as T

type TMap k v = Map k (TVar v)
data ControllerState = ControllerState
	{ _seed :: StdGen
	, _ballotStyles :: Set BallotCode
	-- ballotBox invariant: the bcid in the EncryptedRecord matches the key it's filed under in the Map
	, _ballotBox :: TMap BallotCastingId (BallotStatus, EncryptedRecord)
	}

makeLenses ''ControllerState

main :: IO ()
main = do
	seed <- getStdGen
	statefulErrorServe controller $ ControllerState seed def def

controller :: (MonadError Text m, MonadTransaction ControllerState m, MonadSnap m) => m ()
controller = route $
	[ ("generateCode", do
		method POST
		styleID <- readBodyParam "style"
		code    <- generateCode
		broadcast code styleID
		writeShow code
	  )
	, ("fillOut", do
		method POST
		ballot <- readJSONBody
		transaction (fillOut ballot)
	  )
	, ("cast", do
		method POST
		castingID <- BallotCastingId <$> readBodyParam "bcid"
		setUnknownBallotTo Cast castingID
	  )
	, ("spoil", do
		method POST
		castingID <- BallotCastingId <$> readBodyParam "bcid"
		setUnknownBallotTo Spoiled castingID
	  )
	-- TODO: provisional casting
	]

-- generateCode generates a fresh code by first trying a few random codes; if
-- that doesn't pan out, it searches all possible codes for any it could use
-- {{{
generateCode :: (MonadError Text m, MonadState ControllerState m, Alternative m) => m BallotCode
generateCode = randomCode retries <|> minimalCode where
	retries = 20 -- magic number picked out of a hat

randomCode :: (MonadState ControllerState m, MonadError Text m) => Integer -> m BallotCode
randomCode n
	| n > 0 = do
		c       <- state' seed random
		success <- state' ballotStyles (registerCode c)
		if success then return c else randomCode (n-1)
	| otherwise = throwError "random code search exhausted without finding a fresh code"

minimalCode :: (MonadError Text m, MonadState ControllerState m) => m BallotCode
minimalCode = join $ state' ballotStyles go where
	go db = case S.minView (S.difference allCodes db) of
		Just (code, _) -> (return code, S.insert code db)
		Nothing        -> (throwError "all ballot codes in use", db)

allCodes :: Set BallotCode
allCodes = S.fromList [minBound..maxBound]

registerCode :: BallotCode -> Set BallotCode -> (Bool, Set BallotCode)
registerCode code db
	| not (code `S.member` db) = (True, S.insert code db)
	| otherwise = (False, db)
-- }}}

-- TODO
broadcast :: MonadSnap m => BallotCode -> ID BallotStyle -> m ()
broadcast code styleID = return ()

fillOut :: EncryptedRecord -> ControllerState -> STM ((), ControllerState)
fillOut ballot s = do
	p <- STM.newTVar (Unknown, ballot)
	-- TODO: is it okay to always insert? do we need to check that it
	-- isn't there first or something?
	return ((), set ballotBox (M.insert (_bcid ballot) p (_ballotBox s)) s)

setUnknownBallotTo :: (MonadTransaction ControllerState m, MonadError Text m) => BallotStatus -> BallotCastingId -> m ()
setUnknownBallotTo status bcid = join . transaction_ $ \s -> do
	case M.lookup bcid (_ballotBox s) of
		Just p -> do
			(status, record) <- STM.readTVar p
			case status of
				Unknown -> STM.writeTVar p (status, record) >> return (return ())
				_ -> return (throwError $ T.pack (show bcid) <> " was already " <> T.pack (map toLower (show status)))
		_ -> return (throwError $ "Unknown " <> T.pack (show bcid))

state' :: MonadState s m => Lens s s t t -> (t -> (a, t)) -> m a
state' lens f = state (\s -> second (flip (set lens) s) (f (view lens s)))