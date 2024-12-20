{-# LANGUAGE RecordWildCards  #-}
--
-- INFOB3CC Concurrency
-- Practical 2: Single Source Shortest Path
--
--    Δ-stepping: A parallelisable shortest path algorithm
--    https://www.sciencedirect.com/science/article/pii/S0196677403000762
--
-- https://ics.uu.nl/docs/vakken/b3cc/assessment.html
--
-- https://cs.iupui.edu/~fgsong/LearnHPC/sssp/deltaStep.html
--

module DeltaStepping (

  Graph, Node, Distance,
  deltaStepping,

) where

import Sample
import Utils

import Control.Concurrent
import Control.Concurrent.MVar
import Control.Monad
import Data.Bits
import Data.Graph.Inductive                                         ( Gr )
import Data.IORef
import Data.IntMap.Strict                                           ( IntMap )
import Data.IntSet                                                  ( IntSet)
import Data.Vector.Storable                                         ( Vector )
import Data.Word
import Foreign.Ptr
import Foreign.Storable
import Text.Printf
import qualified Data.Graph.Inductive                               as G
import qualified Data.IntMap.Strict                                 as Map
import qualified Data.IntSet                                        as Set (empty, null, toAscList, delete, insert, union, toList)
import qualified Data.Vector.Mutable                                as V
import qualified Data.Vector.Storable                               as M ( unsafeFreeze )
import qualified Data.Vector.Storable.Mutable                       as M
import Data.Fixed (mod', div')
import Data.Maybe
import Data.Ord (comparing)
import Data.List
import Data.Sequence (chunksOf)


type Graph    = Gr String Distance  -- Graphs have nodes labelled with Strings and edges labelled with their distance
type Node     = Int                 -- Nodes (vertices) in the graph are integers in the range [0..]
type Distance = Float               -- Distances between nodes are (positive) floating point values


-- | Find the length of the shortest path from the given node to all other nodes
-- in the graph. If the destination is not reachable from the starting node the
-- distance is 'Infinity'.
--
-- Nodes must be numbered [0..]
--
-- Negative edge weights are not supported.
--
-- NOTE: The type of the 'deltaStepping' function should not change (since that
-- is what the test suite expects), but you are free to change the types of all
-- other functions and data structures in this module as you require.
--
deltaStepping
    :: Bool                             -- Whether to print intermediate states to the console, for debugging purposes
    -> Graph                            -- graph to analyse
    -> Distance                         -- delta (step width, bucket width)
    -> Node                             -- index of the starting node
    -> IO (Vector Distance)
deltaStepping verbose graph delta source = do
  threadCount <- getNumCapabilities             -- the number of (kernel) threads to use: the 'x' in '+RTS -Nx'

  -- Initialise the algorithm
  (buckets, distances)  <- initialise graph delta source

  let
    -- The algorithm loops while there are still non-empty buckets
    loop = do
      done <- allBucketsEmpty buckets
      if done
      then return ()
      else do
        printVerbose verbose "result" graph delta buckets distances
        step verbose threadCount graph delta buckets distances
        loop
  loop

  printVerbose verbose "result" graph delta buckets distances
  -- Once the tentative distances are finalised, convert into an immutable array
  -- to prevent further updates. It is safe to use this "unsafe" function here
  -- because the mutable vector will not be used any more, so referential
  -- transparency is preserved for the frozen immutable vector.
  --
  -- NOTE: The function 'Data.Vector.convert' can be used to translate between
  -- different (compatible) vector types (e.g. boxed to storable)
  --
  M.unsafeFreeze distances

-- Initialise algorithm state
--
initialise
    :: Graph
    -> Distance
    -> Node
    -> IO (Buckets, TentativeDistances)
initialise graph delta source = do
  -- Making the buckets.
  bucketIndex <- newIORef 0
  arrayOfBuckets <- V.replicate (amountOfBuckets (G.labEdges graph) delta) Set.empty
  let buckets = Buckets bucketIndex arrayOfBuckets
  -- Making the tentative distances.
  distances <- M.replicate (length (G.nodes graph)) infinity
  relax buckets distances delta (source, 0)
  return (buckets, distances)

--The amount of buckets is equal to the highest edge in the graph divided by delta.
amountOfBuckets :: [G.LEdge Float] -> Float -> Int
amountOfBuckets edges delta = ceiling (findLargestEdge edges / delta)

findLargestEdge :: [G.LEdge Float] -> Float
findLargestEdge [] = 0
findLargestEdge ((_, _, x) : xs) = max x (findLargestEdge xs)


-- Take a single step of the algorithm.
-- That is, one iteration of the outer while loop.
--
step
    :: Bool
    -> Int
    -> Graph
    -> Distance
    -> Buckets
    -> TentativeDistances
    -> IO ()
step verbose threadCount graph delta buckets distances = do
  -- In this function, you need to implement the body of the outer while loop,
  -- which contains another while loop.
  -- See function 'deltaStepping' for inspiration on implementing a while loop
  -- in a functional language.
  -- For debugging purposes, you may want to place:
  --   printVerbose verbose "inner step" graph delta buckets distances
  -- in the inner loop.
  
  visitedNodes <- newIORef Set.empty                                                     
  let                                                                                      -- WHILE LOOP 1
    loop2 = do
      done <- isCurrentBucketIsEmpty buckets                                                 --while bucket is not empty
      if done
      then return ()
      else do
        printVerbose verbose "inner step" graph delta buckets distances
        set <- getCurrentBucket buckets                                                    
        requests <- findRequests threadCount (isLightEdge delta) graph set distances        --find light requests
        oldRValue <- readIORef visitedNodes
        writeIORef visitedNodes (Set.union oldRValue set)                                   --remember all the nodes that have been visited for heavy requests
        emptyCurrentBucket buckets                                                          --empty current bucket
        relaxRequests threadCount buckets distances delta requests                          --handle all the requests /put back items in the bucket
        loop2
  loop2                                                                                     -- END WHILE LOOP 1
  rValue <- readIORef visitedNodes
  requests <- findRequests threadCount (isHeavyEdge delta) graph rValue distances           -- find heavy requests
  relaxRequests threadCount buckets distances delta requests                                -- relax heavy requests
  nextBucket <- findNextBucket buckets                                                      --find next empty bucket
  writeIORef (firstBucket buckets) nextBucket                                               --Set next empty bucket


isLightEdge ::Distance -> (Distance -> Bool)
isLightEdge delta distance = distance <= delta

isHeavyEdge ::Distance -> (Distance -> Bool)
isHeavyEdge delta distance = distance > delta


isCurrentBucketIsEmpty :: Buckets -> IO Bool
isCurrentBucketIsEmpty b = do
  set <- getCurrentBucket b
  return (Set.null set)

getCurrentBucket :: Buckets -> IO IntSet
getCurrentBucket (Buckets firstBucket bucketArray) = do
  index <- readIORef firstBucket
  let bucketCount = V.length bucketArray
  let indexModulated = mod index bucketCount
  V.read bucketArray indexModulated

emptyCurrentBucket :: Buckets -> IO()
emptyCurrentBucket (Buckets firstBucket bucketArray) = do
  index <- readIORef firstBucket
  let bucketCount = V.length bucketArray
  let indexModulated = mod index bucketCount
  V.write bucketArray indexModulated Set.empty

-- Once all buckets are empty, the tentative distances are finalised and the
-- algorithm terminates.
--
allBucketsEmpty :: Buckets -> IO Bool
allBucketsEmpty (Buckets _ buckets) = do
  V.foldl (\x y -> x && Set.null y) True buckets

-- Return the index of the smallest on-empty boucket. Assumes that there is at
-- least one non-empty bucket remaining.
--
findNextBucket :: Buckets -> IO Int
findNextBucket (Buckets currentPos buckets) = do
  let totalBuckets = V.length buckets
  currentBucketPos <- readIORef currentPos
  let nextBucket = (currentBucketPos + 1) `mod` totalBuckets
  return nextBucket


-- Create requests of (node, distance) pairs that fulfil the given predicate
--
findRequests
    :: Int
    -> (Distance -> Bool)
    -> Graph
    -> IntSet
    -> TentativeDistances
    -> IO (IntMap Distance)
findRequests threadCount p graph v' distances = do
  let list = Set.toList v'
  -- this is an MVar that the IntMap will be put into
  out <- newMVar Map.empty
  forkThreads threadCount (requestsWork threadCount p graph list distances out)
  takeMVar out

-- This function is used to make sure that each thread gets the same chunk of the list
splitList :: Int -> Int -> [a] -> [a]
splitList threadID threadCount list = [x | (x, num) <- zip list [0..], mod num threadCount == threadID]

requestsWork
    :: Int
    -> (Distance -> Bool)
    -> Graph
    -> [Map.Key]
    -> TentativeDistances
    -> MVar (IntMap Distance)
    -> Int
    -> IO ()
requestsWork threadCount p graph v' distances intmap threadID = do
  -- first get the edges of all the nodes that are in the bucket
  let edges =  concatMap (findRequests' p graph) (splitList threadID threadCount v')
  -- then create the intmap with the new node as key and a distance as value
  listForIntMap <- mapM (calculateNewRequestDistance distances) edges
  a <- takeMVar intmap 
  -- here, we take the intmap so this thread can add its new values to the Intmap
  -- we use insertWith to make sure that duplicate keys are handled correctly
  -- Only the lowest value is needed
  putMVar intmap $ foldl' (\intMap (key, val) -> Map.insertWith min key val intMap) a listForIntMap

-- get the requests
findRequests' :: (Distance -> Bool) -> Graph -> Int -> [G.LEdge Distance]
findRequests' p graph node = filter (\(_, _, node_cost) -> p node_cost) $ G.out graph node :: [G.LEdge Distance]


calculateNewRequestDistance :: TentativeDistances -> G.LEdge Distance -> IO (Node, Distance)
calculateNewRequestDistance distances (node1, node2, distance) = do
  tentDistance <- M.read distances node1
  return (node2, distance + tentDistance)


-- Execute requests for each of the given (node, distance) pairs
--
relaxRequests
    :: Int
    -> Buckets
    -> TentativeDistances
    -> Distance
    -> IntMap Distance
    -> IO ()
relaxRequests threadCount buckets distances delta req = do
  let doRelax = relax buckets distances delta
  mapM_ doRelax (Map.toList req)


-- Execute a single relaxation, moving the given node to the appropriate bucket
-- as necessary
--
relax :: Buckets
      -> TentativeDistances
      -> Distance
      -> (Node, Distance) -- (w, x) in the paper
      -> IO ()
relax buckets distances delta (node, newDistance) = do
  distance <- M.read distances node
  
  when (newDistance < distance) $ do
    --Get the bucket to put the node in.
    let bucketArray' = bucketArray buckets
    let bucketCount = V.length bucketArray'
    let indexModulated = mod (floor (newDistance / delta)) bucketCount
    
    --Remove the node from the current bucket
    bucketToRemoveFrom <- V.readMaybe bucketArray' indexModulated
    when (isJust bucketToRemoveFrom) $ do
      V.modify bucketArray' (Set.delete node) indexModulated

    --Add the node to correct bucket.
    V.modify bucketArray' (Set.insert node) indexModulated
    M.write distances node newDistance

  -- don't do anything if newDistance isn't smaller than the distance already assigned to the node.


-- -----------------------------------------------------------------------------
-- Starting framework
-- -----------------------------------------------------------------------------
--
-- Here are a collection of (data)types and utility functions that you can use.
-- You are free to change these as necessary.
--

type TentativeDistances = M.IOVector Distance

data Buckets = Buckets
  { firstBucket   :: {-# UNPACK #-} !(IORef Int)           -- real index of the first bucket (j)
  , bucketArray   :: {-# UNPACK #-} !(V.IOVector IntSet)   -- cyclic array of buckets
  }


-- The initial tentative distance, or the distance to unreachable nodes
--
infinity :: Distance
infinity = 1/0


-- Forks 'n' threads. Waits until those threads have finished. Each thread
-- runs the supplied function given its thread ID in the range [0..n).
--
forkThreads :: Int -> (Int -> IO ()) -> IO ()
forkThreads n action = do
  -- Fork the threads and create a list of the MVars which per thread tell
  -- whether the action has finished.
  finishVars <- mapM work [0 .. n - 1]
  -- Once all the worker threads have been launched, now wait for them all to
  -- finish by blocking on their signal MVars.
  mapM_ takeMVar finishVars
  where
    -- Create a new empty MVar that is shared between the main (spawning) thread
    -- and the worker (child) thread. The main thread returns immediately after
    -- spawning the worker thread. Once the child thread has finished executing
    -- the given action, it fills in the MVar to signal to the calling thread
    -- that it has completed.
    --
    work :: Int -> IO (MVar ())
    work index = do
      done <- newEmptyMVar
      _    <- forkOn index (action index >> putMVar done ())  -- pin the worker to a given CPU core
      return done


printVerbose :: Bool -> String -> Graph -> Distance -> Buckets -> TentativeDistances -> IO ()
printVerbose verbose title graph delta buckets distances = when verbose $ do
  putStrLn $ "# " ++ title
  printCurrentState graph distances
  printBuckets graph delta buckets distances
  putStrLn "Press enter to continue"
  _ <- getLine
  return ()

-- Print the current state of the algorithm (tentative distance to all nodes)
--
printCurrentState
    :: Graph
    -> TentativeDistances
    -> IO ()
printCurrentState graph distances = do
  printf "  Node  |  Label  |  Distance\n"
  printf "--------+---------+------------\n"
  forM_ (G.labNodes graph) $ \(v, l) -> do
    x <- M.read distances v
    if isInfinite x
       then printf "  %4d  |  %5v  |  -\n" v l
       else printf "  %4d  |  %5v  |  %f\n" v l x
  --
  printf "\n"

printBuckets
    :: Graph
    -> Distance
    -> Buckets
    -> TentativeDistances
    -> IO ()
printBuckets graph delta Buckets{..} distances = do
  first <- readIORef firstBucket
  mapM_
    (\idx -> do
      let idx' = first + idx
      printf "Bucket %d: [%f, %f)\n" idx' (fromIntegral idx' * delta) ((fromIntegral idx'+1) * delta)
      b <- V.read bucketArray (idx' `rem` V.length bucketArray)
      printBucket graph b distances
    )
    [ 0 .. V.length bucketArray - 1 ]

-- Print the current bucket
--
printCurrentBucket
    :: Graph
    -> Distance
    -> Buckets
    -> TentativeDistances
    -> IO ()
printCurrentBucket graph delta Buckets{..} distances = do
  j <- readIORef firstBucket
  b <- V.read bucketArray (j `rem` V.length bucketArray)
  printf "Bucket %d: [%f, %f)\n" j (fromIntegral j * delta) (fromIntegral (j+1) * delta)
  printBucket graph b distances

-- Print a given bucket
--
printBucket
    :: Graph
    -> IntSet
    -> TentativeDistances
    -> IO ()
printBucket graph bucket distances = do
  printf "  Node  |  Label  |  Distance\n"
  printf "--------+---------+-----------\n"
  forM_ (Set.toAscList bucket) $ \v -> do
    let ml = G.lab graph v
    x <- M.read distances v
    case ml of
      Nothing -> printf "  %4d  |   -   |  %f\n" v x
      Just l  -> printf "  %4d  |  %5v  |  %f\n" v l x
  --
  printf "\n"

