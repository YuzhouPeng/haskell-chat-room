{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}


module Main where


import Data.Map (Map)
import qualified Data.List as List
import Data.Hashable
import System.IO
import System.Exit
import Network
import Control.Monad
import Text.Printf
import Control.Concurrent.STM
import GHC.Conc
import Control.Concurrent.Async
import qualified Data.Map as Map

port :: Int
port = 17316

-- Server
-- we use TVar to avoid deadlock
type Server = TVar (Map Int Chatroom)

newServer :: IO Server
newServer = newTVarIO Map.empty

data Message = Notice String
             | Response String
             | Broadcast String
             | Command [[String]] String
             | Error String String
             deriving Show

-- >>
data Client = Client
   { clientName     :: String
   , clientID       :: Int
   , clientHandle   :: Handle
   , clientSendChan :: TChan Message
   }
   
conn :: Handle -> Server -> IO ()
conn handle server = do
  hSetNewlineMode handle universalNewlineMode
  hSetBuffering handle NoBuffering
  putStrLn ">Server Ready..."
  readOp
  return ()
  where
   readOp = do
   --read information from client
     op <- hGetLine handle
     putStrLn $ op ++ " received pre client creation"
     -- analyse information according to different types of information
     -- use case statement
     case words op of
       ["HELO","BASE_TEST"] -> do
         echo $ "HELO text\nIP:10.62.0.97\nPort:" ++ (show port) ++ "\nStudentID:17316109\n"
         -- again, read information from client
         readOp
       ["KILL_SERVICE"] -> output "Successfully kill service" >> return ()
       -- if we want to join the chat room
       ["JOIN_CHATROOM:",roomName] -> do
         -- use arguments to judge the input
         arguments <- getArgs (joinArgs-1)
         case map words arguments of
           -- if the the input follow the client ip + port number + client name :
           [["CLIENT_IP:",_],["PORT:",_],["CLIENT_NAME:",name]] -> do
            -- then began to create new client
             client <- newClient name (hash name) handle
            -- let new client join the chatroom according to the chat room information
             joinChatroom client server roomName
             putStrLn $ "client, "++name++"---"
             putStrLn $ name++" entered " ++ roomName ++ "  " ++ show (hash roomName)
             let msgLines = "CHAT:"++(show $ (hash roomName))++"\nCLIENT_NAME:"++name++"\nMESSAGE:"++name ++ " has joined this chatroom.\n"
             notifyRoom (hash roomName) $ Broadcast msgLines
             runClient server client >> endClient client --(removeClient server client >> return ())
           -- else, the input is invalid
           _ -> output "Unrecognized command" >> readOp
           where
           -- notify room @@@@@@
            notifyRoom roomRef msg = do
              roomsList <- atomically $ readTVar server
              let maybeRoom = Map.lookup roomRef roomsList
              case maybeRoom of
               Nothing    -> putStrLn ("room does not exist " ++ (show roomRef)) >> return True
               Just aRoom -> sendRoomMessage msg aRoom >> return True
            endClient client = do
              putStrLn "Client will be deleted"
              return ()
              --removeClient server client
       _ -> output "Unreconized command" >> debug op >> readOp
       where
        output = hPutStrLn handle 
        getArgs n = replicateM n $ hGetLine handle
        echo s = do
                  putStrLn $ s ++ "returned "
                  output s
                  input <- hGetLine handle
                  echo input


main :: IO ()
main = withSocketsDo $ do 
 server <- newServer
 --listen to port number
 sock <- listenOn (PortNumber (fromIntegral port))
 printf "Listening on port %d\n" port
 forever $ do
   (handle, host, port) <- accept sock
   printf "Accepted connection from %s: %s\n" host (show port)
   -- start the connection process
   forkFinally (talk handle server) (\_ -> hClose handle)