module System.Console.Haskeline.Vi where

import System.Console.Haskeline.Command
import System.Console.Haskeline.Monads
import System.Console.Haskeline.Key
import System.Console.Haskeline.Command.Completion
import System.Console.Haskeline.Command.History
import System.Console.Haskeline.Command.KillRing
import System.Console.Haskeline.Command.Undo
import System.Console.Haskeline.LineState
import System.Console.Haskeline.InputT

import Data.Char(isAlphaNum,isSpace)
import Control.Monad(liftM)

type EitherMode = Either CommandMode InsertMode

type SavedCommand m = Command (ViT m) (ArgMode CommandMode) EitherMode

data ViState m = ViState { 
            lastCommand :: SavedCommand m,
            lastSearch :: [Grapheme]
         }

emptyViState :: Monad m => ViState m
emptyViState = ViState {
            lastCommand = return . Left . argState,
            lastSearch = []
        }

type ViT m = StateT (ViState m) (InputCmdT m)

type InputCmd s t = forall m . Monad m => Command (ViT m) s t
type InputKeyCmd s t = forall m . Monad m => KeyCommand (ViT m) s t

viKeyCommands :: InputKeyCmd InsertMode (Maybe String)
viKeyCommands = choiceCmd [
                simpleChar '\n' +> finish
                , ctrlChar 'd' +> eofIfEmpty viCommands
                , simpleInsertions >+> viCommands
                , simpleChar '\ESC' +> change enterCommandMode
                    >|> viCommandActions
                ]

viCommands :: InputCmd InsertMode (Maybe String)
viCommands = keyCommand viKeyCommands

simpleInsertions :: InputKeyCmd InsertMode InsertMode
simpleInsertions = choiceCmd
                [  simpleKey LeftKey +> change goLeft 
                   , simpleKey RightKey +> change goRight
                   , simpleKey Backspace +> change deletePrev 
                   , simpleKey Delete +> change deleteNext 
                   , simpleKey Home +> change moveToStart
                   , simpleKey End +> change moveToEnd
                   , insertChars
                   , ctrlChar 'l' +> clearScreenCmd
                   , simpleKey UpKey +> historyBack
                   , simpleKey DownKey +> historyForward
                   , searchHistory
                   , simpleKey KillLine +> killFromHelper (SimpleMove moveToStart)
                   , completionCmd (simpleChar '\t')
                   ]

insertChars :: InputKeyCmd InsertMode InsertMode
insertChars = useChar $ loop []
    where
        loop ds d = change (insertChar d) >|> keyChoiceCmd [
                        useChar $ loop (d:ds)
                        , withoutConsuming (storeCharInsertion (reverse ds))
                        ]
        storeCharInsertion s = storeLastCmd $ change (applyArg 
                                                        $ withCommandMode $ insertString s)
                                                >|> return . Left

-- If we receive a ^D and the line is empty, return Nothing
-- otherwise, ignore it.
eofIfEmpty :: (Monad m, Save s) => Command m s (Maybe String)
                        -> Command m s (Maybe String)
eofIfEmpty next s
    | save s == emptyIM = return Nothing
    | otherwise = next s

viCommandActions :: InputCmd CommandMode (Maybe String)
viCommandActions = keyChoiceCmd [
                    simpleChar '\n' +> finish
                    , ctrlChar 'd' +> eofIfEmpty viCommandActions
                    , simpleCmdActions >+> viCommandActions
                    , exitingCommands >+> viCommands
                    , repeatedCommands >+> chooseEitherMode
                    ]
    where
        chooseEitherMode :: InputCmd EitherMode (Maybe String)
        chooseEitherMode (Left cm) = viCommandActions cm
        chooseEitherMode (Right im) = viCommands im

exitingCommands :: InputKeyCmd CommandMode InsertMode
exitingCommands =  choiceCmd [ 
                      simpleChar 'i' +> change insertFromCommandMode
                    , simpleChar 'I' +> change (moveToStart . insertFromCommandMode)
                    , simpleKey Home +> change (moveToStart . insertFromCommandMode)
                    , simpleChar 'a' +> change appendFromCommandMode
                    , simpleChar 'A' +> change (moveToEnd . appendFromCommandMode)
                    , simpleKey End +> change (moveToStart  . insertFromCommandMode)
                    , simpleChar 's' +> change (insertFromCommandMode . deleteChar)
                    , simpleChar 'S' +> noArg >|> killAndStoreI killAll
                    , simpleChar 'C' +> noArg >|> killAndStoreI (SimpleMove moveToEnd)
                    ]

simpleCmdActions :: InputKeyCmd CommandMode CommandMode
simpleCmdActions = choiceCmd [ 
                    simpleChar '\ESC' +> change id -- helps break out of loops
                    , simpleChar 'r'   +> replaceOnce 
                    , simpleChar 'R'   +> replaceLoop
                    , simpleChar 'D' +> noArg >|> killAndStoreCmd (SimpleMove moveToEnd)
                    , ctrlChar 'l' +> clearScreenCmd
                    , simpleChar 'u' +> commandUndo
                    , ctrlChar 'r' +> commandRedo
                    -- vi-mode quirk: history is put at the start of the line.
                    , simpleChar 'j' +> historyForward >|> change moveToStart
                    , simpleChar 'k' +> historyBack >|> change moveToStart
                    , simpleKey DownKey +> historyForward  >|> change moveToStart
                    , simpleKey UpKey +> historyBack >|> change moveToStart
                    , simpleChar '/' +> viSearch '/' Reverse
                    , simpleChar '?' +> viSearch '?' Forward
                    , simpleKey KillLine +> noArg >|> killAndStoreCmd (SimpleMove moveToStart)
                    ]

replaceOnce :: InputCmd CommandMode CommandMode
replaceOnce = try $ changeFromChar replaceChar

repeatedCommands :: InputKeyCmd CommandMode EitherMode
repeatedCommands = choiceCmd [argumented, doBefore noArg repeatableCommands]
    where
        start = foreachDigit startArg ['1'..'9']
        addDigit = foreachDigit addNum ['0'..'9']
        argumented = start >+> loop
        loop = keyChoiceCmd [addDigit >+> loop
                            , repeatableCommands
                            -- if no match, bail out.
                            , withoutConsuming (change argState) >+> return . Left
                            ]

pureMovements :: InputKeyCmd (ArgMode CommandMode) CommandMode
pureMovements = choiceCmd $
            map mkCharCommand charMovements
            ++ map mkSimpleCommand movements
    where
        mkSimpleCommand (k,move) = k +> change (applyCmdArg move)
        mkCharCommand (k,move) = k +> keyChoiceCmd [
                                        useChar (change . applyCmdArg . move)
                                        , withoutConsuming (change argState)
                                        ]

useMovementsForKill :: Command m s t -> (KillHelper -> Command m s t) -> KeyCommand m s t
useMovementsForKill alternate useHelper = choiceCmd $
            map mkCharCommand charMovements
            ++ specialCases
            ++ map (\(k,move) -> k +> useHelper (SimpleMove move)) movements
    where
        specialCases = [ simpleChar 'e' +> useHelper (SimpleMove goToWordDelEnd)
                       , simpleChar 'E' +> useHelper (SimpleMove goToBigWordDelEnd)
                       , simpleChar '%' +> useHelper (GenericKill deleteMatchingBrace)
                       ]
        mkCharCommand (k,move) = k +> keyChoiceCmd [
                                    useChar (useHelper . SimpleMove . move)
                                    , withoutConsuming alternate]


repeatableCommands :: InputKeyCmd (ArgMode CommandMode) EitherMode
repeatableCommands = choiceCmd $
                        [ repeatableCmdToIMode
                        , repeatableCmdMode >+> return . Left
                        , simpleChar '.' +> saveForUndo >|> runLastCommand
                        ]
    where
        runLastCommand s = liftM lastCommand get >>= ($ s)

repeatableCmdMode :: InputKeyCmd (ArgMode CommandMode) CommandMode
repeatableCmdMode = choiceCmd $ 
                    [ simpleChar 'x' +> storedCmdAction 
                                    (saveForUndo >|> change (applyArg deleteChar))
                    , simpleChar 'X' +> storedCmdAction
                                (saveForUndo >|> change (applyArg (withCommandMode deletePrev)))
                    , simpleChar 'p' +> storedCmdAction (pasteCommand pasteGraphemesAfter)
                    , simpleChar 'P' +> storedCmdAction (pasteCommand pasteGraphemesBefore)
                    , simpleChar 'd' +> deletionCmd
                    , simpleChar 'y' +> yankCommand
                    , pureMovements
                    ]

repeatableCmdToIMode :: InputKeyCmd (ArgMode CommandMode) EitherMode
repeatableCmdToIMode = simpleChar 'c' +> deletionToInsertCmd

deletionCmd :: InputCmd (ArgMode CommandMode) CommandMode
deletionCmd = keyChoiceCmd $
                    [simpleChar 'd' +> killAndStoreCmd killAll
                    , useMovementsForKill (change argState) killAndStoreCmd
                    , withoutConsuming (change argState)
                    ]

deletionToInsertCmd :: InputCmd (ArgMode CommandMode) EitherMode
deletionToInsertCmd = keyChoiceCmd $
        [simpleChar 'c' +> killAndStoreIE killAll
        -- vim, for whatever reason, treats cw same as ce and cW same as cE.
        -- readline does this too, so we should also.
        , simpleChar 'w' +> killAndStoreIE (SimpleMove goToWordDelEnd)
        , simpleChar 'W' +> killAndStoreIE (SimpleMove goToBigWordDelEnd)
        , withoutConsuming (return . Left . argState)
        ]


yankCommand :: InputCmd (ArgMode CommandMode) CommandMode
yankCommand = keyChoiceCmd $ 
                [simpleChar 'y' +> copyAndStore killAll
                , useMovementsForKill (change argState) copyAndStore
                , withoutConsuming (change argState)
                ]
    where
        copyAndStore = storedCmdAction . copyFromArgHelper

goToWordDelEnd, goToBigWordDelEnd :: InsertMode -> InsertMode
goToWordDelEnd = goRightUntil $ atStart (not . isWordChar)
                                    .||. atStart (not . isOtherChar)
goToBigWordDelEnd = goRightUntil $ atStart (not . isBigWordChar)


movements :: [(Key,InsertMode -> InsertMode)]
movements = [ (simpleChar 'h', goLeft)
            , (simpleChar 'l', goRight)
            , (simpleChar ' ', goRight)
            , (simpleKey LeftKey, goLeft)
            , (simpleKey RightKey, goRight)
            , (simpleChar '0', moveToStart)
            , (simpleChar '$', moveToEnd)
            , (simpleChar '^', skipRight isSpace . moveToStart)
            , (simpleChar '%', findMatchingBrace)
            ------------------
            -- Word movements
            -- move to the start of the next word
            , (simpleChar 'w', goRightUntil $
                                atStart isWordChar .||. atStart isOtherChar)
            , (simpleChar 'W', goRightUntil (atStart isBigWordChar))
            -- move to the beginning of the previous word
            , (simpleChar 'b', goLeftUntil $
                                atStart isWordChar .||. atStart isOtherChar)
            , (simpleChar 'B', goLeftUntil (atStart isBigWordChar))
            -- move to the end of the current word
            , (simpleChar 'e', goRightUntil $
                                atEnd isWordChar .||. atEnd isOtherChar)
            , (simpleChar 'E', goRightUntil (atEnd isBigWordChar))
            ]

charMovements :: [(Key, Char -> InsertMode -> InsertMode)]
charMovements = [ (simpleChar 'f', \c -> goRightUntil $ overChar (==c))
                       , (simpleChar 'F', \c -> goLeftUntil $ overChar (==c))
                       , (simpleChar 't', \c -> goRightUntil $ beforeChar (==c))
                       , (simpleChar 'T', \c -> goLeftUntil $ afterChar (==c))
                       ]

{- 
From IEEE 1003.1:
A "bigword" consists of: a maximal sequence of non-blanks preceded and followed by blanks
A "word" consists of either:
 - a maximal sequence of wordChars, delimited at both ends by non-wordchars
 - a maximal sequence of non-blank non-wordchars, delimited at both ends by either blanks
   or a wordchar.
-}            
isBigWordChar, isWordChar, isOtherChar :: Char -> Bool
isBigWordChar = not . isSpace
isWordChar = isAlphaNum .||. (=='_')
isOtherChar = not . (isSpace .||. isWordChar)

(.||.) :: (a -> Bool) -> (a -> Bool) -> a -> Bool
f .||. g = \x -> f x || g x

foreachDigit :: (Monad m, LineState t) => (Int -> s -> t) -> [Char] 
                -> KeyCommand m s t
foreachDigit f ds = choiceCmd $ map digitCmd ds
    where digitCmd d = simpleChar d +> change (f (toDigit d))
          toDigit d = fromEnum d - fromEnum '0'

------------------
-- Matching braces

findMatchingBrace :: InsertMode -> InsertMode
findMatchingBrace (IMode xs (y:ys))
    | Just b <- matchingRightBrace yc,
      Just ((b':bs),ys') <- scanBraces yc b ys = IMode (bs++[y]++xs) (b':ys')
    | Just b <- matchingLeftBrace yc,
      Just (bs,xs') <- scanBraces yc b xs = IMode xs' (bs ++ [y]++ys)
  where yc = baseChar y
findMatchingBrace im = im

deleteMatchingBrace :: InsertMode -> ([Grapheme],InsertMode)
deleteMatchingBrace (IMode xs (y:ys))
    | Just b <- matchingRightBrace yc,
      Just (bs,ys') <- scanBraces yc b ys = (y : reverse bs, IMode xs ys')
    | Just b <- matchingLeftBrace yc,
      Just (bs,xs') <- scanBraces yc b xs = (bs ++ [y], IMode xs' ys)
  where yc = baseChar y
deleteMatchingBrace im = ([],im)


scanBraces :: Char -> Char -> [Grapheme] -> Maybe ([Grapheme],[Grapheme])
scanBraces c d = scanBraces' (1::Int) []
    where
        scanBraces' 0 bs xs = Just (bs,xs)
        scanBraces' _ _ [] = Nothing
        scanBraces' n bs (x:xs) = scanBraces' m (x:bs) xs
            where m | baseChar x == c = n+1
                    | baseChar x == d = n-1
                    | otherwise = n

matchingRightBrace, matchingLeftBrace :: Char -> Maybe Char 
matchingRightBrace = flip lookup braceList
matchingLeftBrace = flip lookup (map (\(c,d) -> (d,c)) braceList)

braceList :: [(Char,Char)]
braceList = [('(',')'), ('[',']'), ('{','}')]

---------------
-- Replace mode
replaceLoop :: InputCmd CommandMode CommandMode
replaceLoop = saveForUndo >|> change insertFromCommandMode >|> loop
                >|> change enterCommandModeRight
    where
        loop = try (oneReplaceCmd >+> loop)
        oneReplaceCmd = choiceCmd [
                simpleKey LeftKey +> change goLeft
                , simpleKey RightKey +> change goRight
                , changeFromChar replaceCharIM
                ]


---------------------------
-- Saving previous commands

storeLastCmd :: Monad m => SavedCommand m -> Command (ViT m) s s
storeLastCmd act = \s -> do
        modify $ \vs -> vs {lastCommand = act}
        return s

storedAction :: Monad m => SavedCommand m -> SavedCommand m
storedAction act = storeLastCmd act >|> act

storedCmdAction :: Monad m => Command (ViT m) (ArgMode CommandMode) CommandMode
                            -> Command (ViT m) (ArgMode CommandMode) CommandMode
storedCmdAction act = storeLastCmd (liftM Left . act) >|> act

storedIAction :: Monad m => Command (ViT m) (ArgMode CommandMode) InsertMode
                        -> Command (ViT m) (ArgMode CommandMode) InsertMode
storedIAction act = storeLastCmd (liftM Right . act) >|> act

killAndStoreCmd :: Monad m => KillHelper -> Command (ViT m) (ArgMode CommandMode) CommandMode
killAndStoreCmd = storedCmdAction . killFromArgHelper

killAndStoreI :: Monad m => KillHelper -> Command (ViT m) (ArgMode CommandMode) InsertMode
killAndStoreI = storedIAction . killFromArgHelper

killAndStoreIE :: Monad m => KillHelper -> Command (ViT m) (ArgMode CommandMode) EitherMode
killAndStoreIE helper = storedAction (killFromArgHelper helper >|> return . Right)

noArg :: Monad m => Command m s (ArgMode s)
noArg = return . startArg 1

-------------------
-- Vi-style searching

data SearchEntry = SearchEntry {
                    entryState :: InsertMode,
                    searchChar :: Char
                    }

instance LineState SearchEntry where
    beforeCursor prefix se = beforeCursor (prefix ++ [searchChar se])
                                (entryState se)
    afterCursor = afterCursor . entryState

viSearch :: Monad m => Char -> Direction
                    -> Command (ViT m) CommandMode CommandMode
viSearch c dir s = setState (SearchEntry emptyIM c) >>= loopEntry
    where
        modifySE f se = se {entryState = f (entryState se)}
        loopEntry = keyChoiceCmd [
                        editEntry >+> loopEntry
                        , simpleChar '\n' +> searchHist dir s
                        , withoutConsuming (change (const s))
                        ]
        editEntry = choiceCmd [
                        useChar (change . modifySE . insertChar)
                        , simpleKey LeftKey +> change (modifySE goLeft)
                        , simpleKey RightKey +> change (modifySE goRight)
                        , simpleKey Backspace +> change (modifySE deletePrev)
                        , simpleKey Delete +> change (modifySE deleteNext)
                        ] 

searchHist :: forall m . Monad m
    => Direction -> CommandMode -> SearchEntry -> CmdM (ViT m) CommandMode
searchHist dir cm SearchEntry {entryState = IMode xs ys} = do
    vstate :: ViState m <- get
    let toSearch = reverse xs ++ ys
    let toSearch' = if null toSearch
                        then (lastSearch vstate)
                        else toSearch
    result <- doSearch False SearchMode {
                                    searchTerm = toSearch',
                                    foundHistory = save cm, -- TODO: not needed
                                    direction = dir}
    case result of
        Left e -> effect e >> setState cm
        Right sm -> do
            put vstate {lastSearch = toSearch'}
            setState (restore (foundHistory sm))
