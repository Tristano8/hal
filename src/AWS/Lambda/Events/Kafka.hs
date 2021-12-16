{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE NamedFieldPuns    #-}

{-|
Module      : AWS.Lambda.Events.Kafka
Description : Data types for consuming Kafka events.
License     : BSD3
Stability   : stable

It is possible to subscribe Lambda functions to Kafka topics. You can
subscribe to topics in Amazon Managed Streaming for Kafka (MSK) as
well as self-managed Kafka clusters.

The AWS documentation does not appear to detail the payload format for
Kafka event sources. Lambda considers Amazon Managed Streaming for
Kafka (MSK) to be a different event source type from a self-managed
Apache Kafka cluster, but their payloads are very similar. The types
in this module are derived from inspecting invocation payloads, and
from reading the following blog posts:

  * https://aws.amazon.com/blogs/compute/using-amazon-msk-as-an-event-source-for-aws-lambda/
  * https://aws.amazon.com/blogs/compute/using-self-hosted-apache-kafka-as-an-event-source-for-aws-lambda/

-}

module AWS.Lambda.Events.Kafka (
  KafkaEvent(..),
  EventSource(..),
  Record,
  Record'(..),
  Header (..),
  Timestamp(..),
  -- * Internal
  parseTimestamp,
  unparseTimestamp,
  int64ToUTCTime,
  utcTimeToInt64
) where

import           Data.Aeson
import           Data.Aeson.Types
import           Data.ByteString        (ByteString)
import qualified Data.ByteString        as B
import qualified Data.ByteString.Base64 as B64
import           Data.List.NonEmpty     (NonEmpty)
import qualified Data.List.NonEmpty     as NE
import           Data.Function          ((&))
import qualified Data.HashMap.Strict    as H
import           Data.Int               (Int32, Int64)
import           Data.Map               (Map)
import           Data.Maybe             (catMaybes, maybeToList)
import           Data.Scientific        (toBoundedInteger)
import           Data.Text              (Text)
import qualified Data.Text              as T
import qualified Data.Text.Encoding     as TE
import           Data.Time              (UTCTime)
import           Data.Time.Clock.POSIX  (posixSecondsToUTCTime,
                                         utcTimeToPOSIXSeconds)
import           Data.Vector            (Vector)
import           GHC.Generics           (Generic)

-- | Represents an event from either Amazon MSK or a self-managed
-- Apache Kafka cluster, as the payloads are very similar.
--
-- The 'ToJSON' and 'FromJSON' instances on 'Record' perform base64
-- conversion for you.
--
-- See the <https://docs.aws.amazon.com/lambda/latest/dg/with-kafka.html AWS documentation>
-- for a sample payload.
data KafkaEvent = KafkaEvent {
  eventSource      :: !EventSource,
  -- | Only present when using the "Amazon MSK" event source mapping.
  eventSourceArn   :: !(Maybe Text),
  bootstrapServers :: !(NonEmpty Text),
  -- | The map's keys look like @"${topicName}-${partitionNumber}"@
  records          :: !(Map Text [Record])
} deriving (Eq, Show, Generic)

instance FromJSON KafkaEvent where
  parseJSON = withObject "KafkaEvent" $ \o ->
    let parseBootstrapServers
          = maybe (fail "bootstrapServers: empty string") pure
          . NE.nonEmpty
          . T.splitOn ","
    in KafkaEvent
         <$> o .: "eventSource"
         <*> o .:! "eventSourceArn"
         <*> (o .: "bootstrapServers" >>= parseBootstrapServers)
         <*> o .: "records"

instance ToJSON KafkaEvent where
  toJSON e = object $
    [ "eventSource" .= eventSource e
    , "bootstrapServers" .= T.intercalate "," (NE.toList (bootstrapServers e))
    , "records" .= records e
    ] <> maybeToList (("eventSourceArn" .=) <$> eventSourceArn e)

data EventSource
  = AwsKafka -- ^ @"aws:kafka"@
  | SelfManagedKafka -- ^ @"SelfManagedKafka"@
  deriving (Eq, Show, Bounded, Enum, Ord, Generic)

instance FromJSON EventSource where
  parseJSON = withText "EventSource" $ \case
    "aws:kafka" -> pure AwsKafka
    "SelfManagedKafka" -> pure SelfManagedKafka
    t -> fail $ "unrecognised EventSource: \"" <> show t <> "\""

instance ToJSON EventSource where
  toJSON = \case
    AwsKafka -> String "aws:kafka"
    SelfManagedKafka -> String "SelfManagedKafka"

-- | Convenience alias: most of the time you will parse the records
-- straight into some app-specific structure.
type Record = Record' ByteString

-- | Records from a Kafka event. This is 'Traversable', which means
-- you can do things like parse a JSON-encoded payload:
--
-- @
-- 'traverse' 'decodeStrict' :: 'FromJSON' a => Record ByteString -> Maybe (Record a)
-- @
data Record' a = Record {
  topic :: !Text,
  partition :: !Int32,
  offset :: !Int64,
  timestamp :: !Timestamp,
  -- | NOTE: there can be multiple headers for a given key.
  headers :: !(Vector Header),
  key :: !(Maybe ByteString),
  value :: !(Maybe a)
} deriving (Eq, Show, Generic, Functor, Foldable, Traversable)

-- | Decodes base64-encoded keys and values, where present.
instance a ~ ByteString => FromJSON (Record' a) where
  parseJSON = withObject "Record" $ \o -> do
    topic <- o .: "topic"
    partition <- o .: "partition"
    offset <- o .: "offset"
    timestamp <- parseTimestamp o
    headers <- o .: "headers"
    key <- fmap (B64.decodeLenient . TE.encodeUtf8) <$> o .:? "key"
    value <- fmap (B64.decodeLenient . TE.encodeUtf8) <$> o .:? "value"
    pure Record { topic, partition, offset, timestamp, headers, key, value }

-- | Encodes keys and values into base64.
instance a ~ ByteString => ToJSON (Record' a) where
  toJSON r = object $ concat
    [
      [ "offset" .= offset r
      , "partition" .= partition r
      , "topic" .= topic r
      , "headers" .= headers r
      ]
    , unparseTimestamp (timestamp r)
    , catMaybes
      [ ("key" .=) . TE.decodeUtf8 . B64.encode <$> key r
      , ("value" .=) . TE.decodeUtf8 . B64.encode <$> value r
      ]
    ]

-- | AWS serialises record headers to JSON as an array of
-- objects. From their docs:
--
-- @
-- "headers":[{"headerKey":[104, 101, 97, 100, 101, 114, 86, 97, 108, 117, 101]}]
-- @
--
-- Note:
--
-- >>> map chr [104, 101, 97, 100, 101, 114, 86, 97, 108, 117, 101]
-- "headerValue"
data Header = Header !Text !ByteString deriving (Eq, Show, Generic)

instance FromJSON Header where
  parseJSON = withObject "header" $ \o ->
    case H.toList o of
      [(key, value)] -> Header key . B.pack <$> parseJSON value
      [] -> fail "Unexpected empty object"
      _ -> fail "Unexpected additional keys in object"

instance ToJSON Header where
  toJSON (Header key value) = object [key .= B.unpack value]

-- | Kafka timestamp types, derived from the Java client's enum at:
-- https://github.com/apache/kafka/blob/trunk/clients/src/main/java/org/apache/kafka/common/record/TimestampType.java
data Timestamp = NoTimestampType | CreateTime !UTCTime | LogAppendTime !UTCTime
  deriving (Eq, Show, Generic)

parseTimestamp :: Object -> Parser Timestamp
parseTimestamp o = explicitParseField parseSubtype o "timestampType"
  where
    parseSubtype = withText "timestampType" $ \case
      "NO_TIMESTAMP_TYPE" -> pure NoTimestampType
      "CREATE_TIME" -> CreateTime <$> parseUTCTimestamp
      "LOG_APPEND_TIME" -> LogAppendTime <$> parseUTCTimestamp
      t -> fail $ "unknown timestampType: \"" <> show t <> "\""

    parseUTCTimestamp = explicitParseField convertToUTCTime o "timestamp"

    convertToUTCTime = withScientific "timestamp" $ \stamp ->
      int64ToUTCTime <$> (toBoundedInteger stamp &
        maybe (fail "timestamp out of range") pure :: Parser Int64)

unparseTimestamp :: KeyValue kv => Timestamp -> [kv]
unparseTimestamp = \case
  NoTimestampType -> ["timestampType" .= String "NO_TIMESTAMP_TYPE"]
  CreateTime ts ->
    [ "timestampType" .= String "CREATE_TIME"
    , "timestamp" .= utcTimeToInt64 ts
    ]
  LogAppendTime ts ->
    [ "timestampType" .= String "LOG_APPEND_TIME"
    , "timestamp" .= utcTimeToInt64 ts
    ]

int64ToUTCTime :: Int64 -> UTCTime
int64ToUTCTime int =
  let (seconds, millis) = int `divMod` 1000
      posixSeconds = fromIntegral seconds + fromIntegral millis / 1000
  in posixSecondsToUTCTime posixSeconds

utcTimeToInt64 :: UTCTime -> Int64
utcTimeToInt64 utc = truncate $ utcTimeToPOSIXSeconds utc * 1000
