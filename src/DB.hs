{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE QuasiQuotes #-}

module DB where

import Control.Monad (mapM)
import qualified Control.Monad.Trans as MonadTrans (liftIO)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy.Char8 as ByteStringLazyChar8
import qualified Data.Char as Char
import qualified Data.HashMap.Strict as HashMap
import qualified Data.Pool as Pool
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import qualified Data.Text.Read as TextRead
import qualified Database.Mbtiles as Mbtiles
import qualified Database.PostgreSQL.Simple as PGSimple
import qualified Database.PostgreSQL.Simple.SqlQQ as PGQQ
import qualified Database.SQLite.Simple as SQLiteSimple
import qualified Database.SQLite.Simple.QQ as SQQQ
import qualified Errors
import qualified Servant
import qualified Types
import qualified Types.Api as ApiTypes
import qualified Types.DB as DBTypes
import qualified Types.Metric as MetricTypes
import qualified Types.MetricData as MetricDataTypes
import qualified Types.Scenario as ScenarioTypes
import qualified Types.Template as TemplateTypes
import qualified Types.Template.Map as MapTemplateTypes

--

getScenarioDetailDBForYear :: DBTypes.DatabaseEngine a -> ScenarioTypes.ScenarioId -> Types.Year -> Servant.Handler ApiTypes.ComparisonListData
getScenarioDetailDBForYear dbEngine scenarioId year = do
  metrics <- fmap MetricDataTypes.metricListToHashMap $ metricsDBForYear dbEngine scenarioId year
  scenario <- scenarioDB dbEngine scenarioId
  return $ ApiTypes.ComparisonListData metrics scenario year

getScenarioDetailDB :: DBTypes.DatabaseEngine a -> ScenarioTypes.ScenarioId -> Types.Year -> Servant.Handler TemplateTypes.TemplateData
getScenarioDetailDB dbEngine scenarioId year = do
  metrics <- fmap MetricDataTypes.metricListToHashMap $ metricsDB dbEngine scenarioId
  scenario <- scenarioDB dbEngine scenarioId
  return $ TemplateTypes.TemplateData metrics scenario year ""

getScenarioDetailTemplate :: DBTypes.DatabaseEngine a -> ScenarioTypes.ScenarioId -> Types.Year -> String -> Servant.Handler TemplateTypes.TemplateData
getScenarioDetailTemplate dbEngine scenarioId year host = do
  metrics <- fmap MetricDataTypes.metricListToHashMap $ metricsDBForYear dbEngine scenarioId year
  scenario <- scenarioDB dbEngine scenarioId
  return $ TemplateTypes.TemplateData metrics scenario year host

getScenarioMapDB :: DBTypes.DatabaseEngine a -> ScenarioTypes.ScenarioId -> MetricTypes.MetricId -> String -> Servant.Handler MapTemplateTypes.MapTemplateData
getScenarioMapDB dbEngine scenarioId metricId host = do
  spatialData <- fmap MetricTypes.spatialMetricsToHashMap $ spatialDataDB dbEngine scenarioId metricId
  metricData <- metricDB dbEngine metricId
  scenario <- scenarioDB dbEngine scenarioId
  return $ MapTemplateTypes.MapTemplateData spatialData metricData scenario host

getScenarioComparisonListDB :: DBTypes.DatabaseEngine a -> [ScenarioTypes.ScenarioId] -> Types.Year -> Servant.Handler [ApiTypes.ComparisonListData]
getScenarioComparisonListDB dbEngine scenarioIds year =
  let toTD :: Types.Year -> ScenarioTypes.Scenario -> Servant.Handler ApiTypes.ComparisonListData
      toTD year scenario = do
        metrics <- fmap MetricDataTypes.metricListToHashMap $ metricsDBForYear dbEngine (ScenarioTypes.scenarioId scenario) year
        pure $ ApiTypes.ComparisonListData metrics scenario year
   in do
        -- TODO: What happens if there is no data for a scenario in the requested year.
        scenarios <- scenariosSelectDB dbEngine scenarioIds
        mapM (toTD year) scenarios

getScenarioComparisonMetrics :: DBTypes.DatabaseEngine a -> ScenarioTypes.ScenarioId -> ScenarioTypes.ScenarioId -> Servant.Handler [MetricTypes.MetricName]
getScenarioComparisonMetrics dbEngine scenarioId1 scenarioId2 =
  MonadTrans.liftIO $ action
  where
    action =
      case dbEngine of
        DBTypes.SQLite3 conns -> Pool.withResource conns $ \conn ->
          SQLiteSimple.query
            conn
            sqQuery
            (scenarioId1, scenarioId2)
        DBTypes.PostgreSQL conns -> Pool.withResource conns $ \conn ->
          PGSimple.query
            conn
            pgQuery
            (scenarioId1, scenarioId2)
    sqQuery =
      [SQQQ.sql| 
        select distinct metric_id, m.name 
        from metric_data 
        join (select id, name from metrics) as m on metric_id = m.id 
        where scenario_id in (?, ?) 
        order by metric_id
        |]
    pgQuery =
      [PGQQ.sql| 
        select distinct metric_id, m.name 
        from metric_data 
        join (select id, name from metrics) as m on metric_id = m.id 
        where scenario_id in (?, ?) 
        order by metric_id
        |]

scenarioDB ::
  DBTypes.DatabaseEngine a ->
  ScenarioTypes.ScenarioId ->
  Servant.Handler ScenarioTypes.Scenario
scenarioDB dbEngine scenarioId = do
  res <-
    MonadTrans.liftIO $ action
  case res of
    x : xs ->
      return x
    _ ->
      Servant.throwError Servant.err401 {Servant.errBody = Errors.errorString "401" "No results found" "Try a different scenario or contact your support team."}
  where
    action =
      case dbEngine of
        DBTypes.SQLite3 conns -> Pool.withResource conns $ \conn ->
          SQLiteSimple.query
            conn
            sqQuery
            (SQLiteSimple.Only $ scenarioId)
        DBTypes.PostgreSQL conns -> Pool.withResource conns $ \conn ->
          PGSimple.query
            conn
            pgQuery
            (PGSimple.Only $ scenarioId)
    sqQuery =
      [SQQQ.sql| 
        SELECT id, name, description, assumptions, md.years 
        from scenarios 
        join (
          select json_group_array(year) as years, scenario_id 
          from (select distinct year, scenario_id from metric_data order by year) as a group by scenario_id 
          ) as md 
        on scenarios.id = md.scenario_id 
        where scenario_id = ?
        |]
    pgQuery =
      [PGQQ.sql| 
        SELECT id, name, description, assumptions, md.years 
        from scenarios 
        join (
            select json_agg(year) as years, scenario_id 
            from (select distinct year, scenario_id from metric_data order by year) 
            as a group by scenario_id 
            ) as md 
        on scenarios.id = md.scenario_id 
        where scenario_id = ?
        |]

scenariosSelectDB ::
  DBTypes.DatabaseEngine a ->
  [ScenarioTypes.ScenarioId] ->
  Servant.Handler [ScenarioTypes.Scenario]
scenariosSelectDB dbEngine scenarioIds =
  mapM
    ( scenarioDB dbEngine
    )
    scenarioIds

scenariosDB ::
  DBTypes.DatabaseEngine a ->
  Servant.Handler [ScenarioTypes.Scenario]
scenariosDB dbEngine =
  MonadTrans.liftIO $ action
  where
    action =
      case dbEngine of
        DBTypes.SQLite3 conns -> Pool.withResource conns $ \conn ->
          SQLiteSimple.query_
            conn
            sqQuery
        DBTypes.PostgreSQL conns -> Pool.withResource conns $ \conn ->
          PGSimple.query_
            conn
            pgQuery
    sqQuery =
      [SQQQ.sql|
        SELECT id, name, description, assumptions, md.years
        from scenarios
                join (select json_group_array(year) as years, scenario_id
                      from (select distinct year, scenario_id from metric_data order by year) as a
                      group by scenario_id) as md on scenarios.id = md.scenario_id      
      |]
    pgQuery =
      [PGQQ.sql|
        SELECT id, name, description, assumptions, md.years
        from scenarios
                join (select json_agg(year) as years, scenario_id
                      from (select distinct year, scenario_id from metric_data order by year) as a
                      group by scenario_id) as md on scenarios.id = md.scenario_id      
      |]

metricsDBForYear ::
  DBTypes.DatabaseEngine a ->
  ScenarioTypes.ScenarioId ->
  Types.Year ->
  Servant.Handler [MetricDataTypes.MetricData]
metricsDBForYear dbEngine scenarioId year =
  MonadTrans.liftIO $
    action
  where
    action =
      case dbEngine of
        DBTypes.SQLite3 conns -> Pool.withResource conns $ \conn ->
          SQLiteSimple.query
            conn
            sqQuery
            (year, scenarioId, year)
        DBTypes.PostgreSQL conns -> Pool.withResource conns $ \conn ->
          PGSimple.query
            conn
            pgQuery
            (year, scenarioId, year)
    sqQuery =
      [SQQQ.sql|
              SELECT scenario_id,
                    metric_id,
                    m.name,
                    m.description,
                    m.low_outcome,
                    m.low_outcome_text,
                    m.high_outcome,
                    m.high_outcome_text,
                    m.aggregate_bins,
                    m.spatial_bins,
                    m.unit,
                    metric_data.year,
                    value,
                    spatial_data.spatial_values
              from metric_data
                    join (select id, name, description, low_outcome, low_outcome_text, high_outcome,high_outcome_text, json(aggregate_bins) as aggregate_bins, json(spatial_bins) as spatial_bins, unit from metrics group by id) as m on metric_data.metric_id = m.id
                    left join (select zonal_data.metric_id as id,
                                      json_group_array(
                                              json_object('id', zone_id, 'value', value)
                                          )                      as spatial_values, year
                              from zonal_data
                              where year = ?
                              group by metric_id, year) as spatial_data on metric_data.metric_id = spatial_data.id and metric_data.year = spatial_data.year
              where scenario_id = ? and metric_data.year = ?
              order by metric_id;
            |]
    pgQuery =
      [PGQQ.sql|
              SELECT scenario_id,
                    metric_id,
                    m.name,
                    m.description,
                    m.low_outcome,
                    m.low_outcome_text,
                    m.high_outcome,
                    m.high_outcome_text,
                    m.aggregate_bins,
                    m.spatial_bins,
                    m.unit,
                    metric_data.year,
                    value,
                    spatial_data.spatial_values
              from metric_data
                    join (select id, name, description, low_outcome, low_outcome_text, high_outcome,high_outcome_text, json(aggregate_bins) as aggregate_bins, json(spatial_bins) as spatial_bins, unit from metrics group by id) as m on metric_data.metric_id = m.id
                    left join (select zonal_data.metric_id as id,
                                      json_group_array(
                                              json_object('id', zone_id, 'value', value)
                                          )                      as spatial_values, year
                              from zonal_data
                              where year = ?
                              group by metric_id, year) as spatial_data on metric_data.metric_id = spatial_data.id and metric_data.year = spatial_data.year
              where scenario_id = ? and metric_data.year = ?
              order by metric_id;
            |]

metricsDB ::
  DBTypes.DatabaseEngine a ->
  ScenarioTypes.ScenarioId ->
  Servant.Handler [MetricDataTypes.MetricData]
metricsDB dbEngine scenarioId =
  MonadTrans.liftIO $
    action
  where
    action =
      case dbEngine of
        DBTypes.SQLite3 conns -> Pool.withResource conns $ \conn ->
          SQLiteSimple.query
            conn
            sqQuery
            (SQLiteSimple.Only scenarioId)
        DBTypes.PostgreSQL conns -> Pool.withResource conns $ \conn ->
          PGSimple.query
            conn
            pgQuery
            (PGSimple.Only scenarioId)
    sqQuery =
      [SQQQ.sql|
            SELECT scenario_id,
                  metric_id,
                  m.name,
                  m.description,
                  m.low_outcome,
                  m.low_outcome_text,
                  m.high_outcome,
                  m.high_outcome_text,
                  m.aggregate_bins,
                  m.spatial_bins,
                  m.unit,
                  metric_data.year,
                  value,
                  spatial_data.spatial_values
            from metric_data
                  join (select id, name, description, low_outcome, low_outcome_text, high_outcome,high_outcome_text, json(aggregate_bins) as aggregate_bins, json(spatial_bins) as spatial_bins, unit from metrics group by id) as m on metric_data.metric_id = m.id
                  left join (select zonal_data.metric_id as id,
                                    json_group_array(
                                            json_object('id', zone_id, 'value', value)
                                        )                      as spatial_values, year
                            from zonal_data
                            group by metric_id, year) as spatial_data on metric_data.metric_id = spatial_data.id and metric_data.year = spatial_data.year
            where scenario_id = ?
            order by metric_id;
            |]
    pgQuery =
      [PGQQ.sql|
            SELECT scenario_id,
                  metric_id,
                  m.name,
                  m.description,
                  m.low_outcome,
                  m.low_outcome_text,
                  m.high_outcome,
                  m.high_outcome_text,
                  m.aggregate_bins,
                  m.spatial_bins,
                  m.unit,
                  metric_data.year,
                  value,
                  spatial_data.spatial_values
            from metric_data
                  join (select id, name, description, low_outcome, low_outcome_text, high_outcome,high_outcome_text, json(aggregate_bins) as aggregate_bins, json(spatial_bins) as spatial_bins, unit from metrics group by id) as m on metric_data.metric_id = m.id
                  left join (select zonal_data.metric_id as id,
                                    json_group_array(
                                            json_object('id', zone_id, 'value', value)
                                        )                      as spatial_values, year
                            from zonal_data
                            group by metric_id, year) as spatial_data on metric_data.metric_id = spatial_data.id and metric_data.year = spatial_data.year
            where scenario_id = ?
            order by metric_id;
            |]

spatialDataDB ::
  DBTypes.DatabaseEngine a ->
  ScenarioTypes.ScenarioId ->
  MetricTypes.MetricId ->
  Servant.Handler [MetricTypes.SpatialData]
spatialDataDB dbEngine scenarioId metricId =
  MonadTrans.liftIO $
    action
  where
    action =
      case dbEngine of
        DBTypes.SQLite3 conns -> Pool.withResource conns $ \conn ->
          SQLiteSimple.query
            conn
            sqQuery
            (metricId, scenarioId)
        DBTypes.PostgreSQL conns -> Pool.withResource conns $ \conn ->
          PGSimple.query
            conn
            pgQuery
            (metricId, scenarioId)
    sqQuery =
      [SQQQ.sql|
          select year, 
                json_group_array(
                        json_object('id', zone_id, 'value', value)
                    ) as spatial_values
          from zonal_data
          where metric_id = ? and scenario_id = ?
          group by year
        |]

pgQuery =
  [PGQQ.sql|
          select year, 
                json_group_array(
                        json_object('id', zone_id, 'value', value)
                    ) as spatial_values
          from zonal_data
          where metric_id = ? and scenario_id = ?
          group by year
        |]

metricDB ::
  DBTypes.DatabaseEngine a ->
  MetricTypes.MetricId ->
  Servant.Handler MetricTypes.Metric
metricDB dbEngine metricId = do
  res <- MonadTrans.liftIO $ action
  case res of
    x : xs ->
      return x
    _ ->
      Servant.throwError Servant.err401 {Servant.errBody = Errors.errorString "401" "No results found" "Try a different scenario or contact your support team."}
  where
    action =
      case dbEngine of
        DBTypes.SQLite3 conns -> Pool.withResource conns $ \conn ->
          SQLiteSimple.query
            conn
            sqQuery
            (SQLiteSimple.Only $ metricId)
        DBTypes.PostgreSQL conns -> Pool.withResource conns $ \conn ->
          PGSimple.query
            conn
            pgQuery
            (PGSimple.Only $ metricId)
    sqQuery =
      [SQQQ.sql|
        select id, name, description, low_outcome, low_outcome_text, high_outcome,high_outcome_text, json(aggregate_bins) as aggregate_bins, json(spatial_bins) as spatial_bins, unit 
        from metrics 
        where id = ?
      |]
    pgQuery =
      [PGQQ.sql|
          select id, name, description, low_outcome, low_outcome_text, high_outcome,high_outcome_text, json(aggregate_bins) as aggregate_bins, json(spatial_bins) as spatial_bins, unit 
          from metrics 
          where id = ?
        |]

tilesDB ::
  HashMap.HashMap Text.Text Mbtiles.MbtilesPool ->
  Text.Text ->
  Int ->
  Int ->
  Text.Text ->
  Servant.Handler BS.ByteString
tilesDB conns mbtilesFilename z x stringY
  | (".mvt" `Text.isSuffixOf` stringY) || (".pbf" `Text.isSuffixOf` stringY) || (".vector.pbf" `Text.isSuffixOf` stringY) =
    case HashMap.lookup mbtilesFilename conns of
      Just conns ->
        getAnything conns z x stringY
      Nothing ->
        Servant.throwError $ Servant.err400 {Servant.errBody = "Could not find mbtiles file: " <> ByteStringLazyChar8.fromStrict (TextEncoding.encodeUtf8 mbtilesFilename)}
  | otherwise = Servant.throwError $ Servant.err400 {Servant.errBody = "Unknown request: " <> ByteStringLazyChar8.fromStrict (TextEncoding.encodeUtf8 stringY)}

getAnything ::
  Mbtiles.MbtilesPool ->
  Int ->
  Int ->
  Text.Text ->
  Servant.Handler BS.ByteString
getAnything conns z x stringY =
  case getY stringY of
    Left e -> Servant.throwError $ Servant.err400 {Servant.errBody = "Unknown request: " <> ByteStringLazyChar8.fromStrict (TextEncoding.encodeUtf8 stringY)}
    Right (y, _) -> getTile conns z x y
  where
    getY s = TextRead.decimal $ Text.takeWhile Char.isNumber s

getTile :: Mbtiles.MbtilesPool -> Int -> Int -> Int -> Servant.Handler BS.ByteString
getTile conns z x y = do
  res <- MonadTrans.liftIO $ action
  case res of
    Just a ->
      return a
    _ ->
      Servant.throwError Servant.err404 {Servant.errBody = Errors.errorString "404" "No tiles found" "Try requesting a different tile."}
  where
    action =
      Mbtiles.runMbtilesPoolT conns (Mbtiles.getTile (Mbtiles.Z z) (Mbtiles.X x) (Mbtiles.Y y))
