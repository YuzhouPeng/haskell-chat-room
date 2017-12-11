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

sendMsgArgs :: Int
sendMsgArgs = 5
joinArgs :: Int
joinArgs = 4
leaveArgs :: Int
leaveArgs = 3
killService :: String
killService = "KILL"
port :: Int
port = 17316
disconnectArgs :: Int
disconnectArgs = 3

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

data Client = Client
   { clientName     :: String
   , clientID       :: Int
   , clientHandle   :: Handle
   , clientSendChan :: TChan Message
   }
   
data Chatroom = Chatroom
  { roomName :: String
  , roomRef  :: Int
  , members  :: TVar (Map Int Client)
  }

newChatroom :: Client -> String -> STM Chatroom
newChatroom joiner@Client{..} room = do
  clientList <- newTVar $ Map.insert clientID joiner Map.empty
  return Chatroom { roomName = room
                  , roomRef  = hash room
                  , members  = clientList
                  }

getChatroom :: Int -> Server -> STM (Maybe Chatroom)
getChatroom roomRef serv = do
  rooms <- readTVar serv
  case Map.lookup roomRef rooms of
   Nothing -> return Nothing
   Just x  -> return $ Just x

joinChatroom :: Client -> Server -> String -> IO ()
joinChatroom joiner@Client{..} rooms name = atomically $ do
  roomList <- readTVar rooms
  case Map.lookup (hash name) roomList of
  --if there is no room num, we will create a new room, and add client
    Nothing -> do
      room <- newChatroom joiner name
      let updatedRoomList = Map.insert (roomRef room) room roomList
      writeTVar rooms updatedRoomList
      sendResponse (roomRef room) (roomName room)
    -- if there is an existing room, add client and update information
    Just aRoom -> do
      clientList <- readTVar (members aRoom)
      let newClientList = Map.insert clientID joiner clientList
      writeTVar (members aRoom) newClientList
      sendResponse (roomRef aRoom) (roomName aRoom)
    where
     sendResponse ref name = sendMessage joiner (Response $ "JOINED_CHATROOM:"++name++"\nSERVER_IP:10.62.0.97\nPORT:"++show (fromIntegral port) ++ "\nROOM_REF:" ++ show ref ++"\nJOIN_ID:" ++ show (ref+clientID))

leaveChatroom :: Client -> Server -> Int -> IO ()
leaveChatroom client@Client{..} server roomRef = do
  leave' client server roomRef (roomRef+clientID)
  return ()

leave' :: Client -> Server -> Int -> Int -> IO ()
leave' client@Client{..} server roomRef joinRef = do
  roomList <- atomically $ readTVar server
  case Map.lookup roomRef roomList of
    Nothing    -> putStrLn "Room does not exist" 
    Just aRoom -> do
      atomically $ sendMessage client (Response $ "LEFT_CHATROOM:" ++ show roomRef ++ "\nJOIN_ID:" ++ show joinRef)
      removeUser -- >> sendRoomMessage notification aRoom >> atomically (sendMessage client notification)
      putStrLn ("removing " ++ clientName ++ "the number messages sent")
      putStrLn $ clientName++" left " ++ (roomName aRoom)
      putStrLn $ "remove looks like: " ++ (show notification)
      where
       removeUser = atomically $ do
         clientList <- readTVar (members aRoom)
         let roomMembers = Map.elems clientList
         mapM_ (\aClient -> sendMessage aClient notification) roomMembers
         let newList = Map.delete (hash clientName) clientList
         writeTVar (members aRoom) newList
       notification = (Broadcast $ "CHAT:" ++ (show roomRef) ++ "\nCLIENT_NAME:" ++ clientName ++ "\nMESSAGE:" ++ clientName ++ " has left this chatroom.\n")

deleteChatroom :: Server -> Int -> IO ()
deleteChatroom serv ref = atomically $ do 
  list <- readTVar serv
  case Map.lookup ref list of
    Nothing    -> return ()
    Just aRoom -> do
      let newList = Map.delete ref list
      writeTVar serv newList

sendMessage :: Client -> Message -> STM ()
sendMessage Client{..} = writeTChan clientSendChan

sendRoomMessage :: Message -> Chatroom -> IO ()
sendRoomMessage msg room@Chatroom{..} = do
  atomically $ notifyRoom
  putStrLn $ "sRM " ++ (show msg)
  where
   notifyRoom = do
    memberList <- readTVar members
    let roomMembers = Map.elems memberList
    mapM_ (\aClient -> sendMessage aClient msg) roomMembers



newClient :: String -> Int -> Handle -> IO Client
newClient name id handle = do
  c <- newTChanIO
  return Client { clientName     = name
                , clientID       = id
                , clientHandle   = handle
                , clientSendChan = c
                }

runClient :: Server -> Client -> IO ()
runClient serv client@Client{..} = do
  putStrLn "hello"
  race server receive
  putStrLn "round finished"
  return ()
  where
   receive = forever $ do
     putStrLn "receiving"
     -- get first line information and redirect to different function
     msg <- hGetLine clientHandle
     putStrLn $ msg ++ " received"
     case words msg of
       ["JOIN_CHATROOM:",roomName] -> do
         cmdLineArgs <- getArgs (joinArgs-1)
         send cmdLineArgs roomName
       ["LEAVE_CHATROOM:",roomRef] -> do
         cmdLineArgs <- getArgs (leaveArgs-1)
         mapM_ putStrLn cmdLineArgs
         send cmdLineArgs roomRef
       ["DISCONNECT:",ip]          -> do
         cmdLineArgs <- getArgs (disconnectArgs-1)
         putStrLn "disconnect command"
         send cmdLineArgs ip
       ["CHAT:",roomRef]           -> do
         cmdLineArgs <- getArgs (sendMsgArgs-1)
         send cmdLineArgs roomRef
       ["KILL_SERVICE"]            -> do
         send [killService] killService
       _                           -> debug msg >> throwError
       where
        send :: [String] -> String -> IO ()
        send args initialArg = atomically   $ sendMessage client $ Command (map words args) initialArg
        throwError           = atomically   $ sendMessage client $ Error "Error 1" "Unrecognised Command"
        getArgs n            = replicateM n $ hGetLine clientHandle
   server = join $ atomically $ do
     msg <- readTChan clientSendChan
     return $ do 
       continue <- handleMessage serv client msg
       when continue $ server


removeClient :: Server -> Client -> IO ()
removeClient serv toRemove@Client{..} = do
  rooms <- atomically $ readTVar serv
  putStrLn "in remove client, server read"
  let roomNames = Prelude.map (\room -> roomName room) (Map.elems rooms)
  putStrLn "roomNames obtained"
  putStrLn $ show roomNames

  mapM_ (\room -> kickFrom room) roomNames
  where
   kickFrom room = do 
     putStrLn ("removing " ++ clientName ++ " from " ++ room)
     leaveChatroom toRemove serv (hash room) >> putStrLn (clientName ++ " removed from " ++ room)

handleMessage :: Server -> Client -> Message -> IO Bool
handleMessage server client@Client{..} message =
  case message of
    Notice    msg       -> output $ msg
    Response  msg       -> output $ msg
    Broadcast msg       -> output $ msg
    Error heading body  -> output $ "->" ++ heading ++ "<-\n" ++ body
    Command msg mainArg -> case msg of

      [["CLIENT_IP:",_],["PORT:",_],["CLIENT_NAME:",name]] -> do
        putStrLn ("joining joinRef = " ++ show (clientID + (hash mainArg)))
        let msgLines = "CHAT:"++(show $ (hash mainArg))++"\nCLIENT_NAME:"++clientName++"\nMESSAGE:"++clientName ++ " has joined this chatroom.\n"
        joinChatroom client server mainArg >> notifyRoom (hash mainArg) (Broadcast msgLines)

      [["JOIN_ID:",id],["CLIENT_NAME:",name]] -> do
        putStrLn ("leave room joinref = " ++ id)
        leave' client server (read mainArg :: Int) (read id :: Int)
        putStrLn "chatroom left success"
        return True


      [["PORT:",_],["CLIENT_NAME:",name]] -> putStrLn "disconnecting user" >> removeClient server client >> return True


      [["JOIN_ID:",id],["CLIENT_NAME:",name],("MESSAGE:":msgToSend),[]] -> do
        notifyRoom (read mainArg :: Int) $ Broadcast ("CHAT: " ++ mainArg ++ "\nCLIENT_NAME: " ++ name ++ "\nMESSAGE: "++(unwords msgToSend)++"\n")


      [["KILL"]]                         -> do
        if mainArg == killService then return False
        else return True

      
      _ -> do
        atomically   $ sendMessage client $ Error "Error 1" "Unrecognised Args"
        mapM_ putStrLn $ map unwords msg
        putStrLn "Error didnt recognise command"
        return True
      where
       reply replyMsg = atomically $ sendMessage client replyMsg
       notifyRoom roomRef msg = do
         roomsList <- atomically $ readTVar server
         let maybeRoom = Map.lookup roomRef roomsList
         case maybeRoom of
           Nothing    -> putStrLn ("room does not exist " ++ (show roomRef)) >> return True
           Just aRoom -> sendRoomMessage msg aRoom >> return True
  where
   output s = do putStrLn (clientName ++ " receiving\\/\n" ++ s) >> hPutStrLn clientHandle s; return True


debug :: String -> IO ()
debug = putStrLn
   
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
   forkFinally (conn handle server) (\_ -> hClose handle)
