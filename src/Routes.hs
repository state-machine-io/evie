{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Routes where

import qualified Data.ByteString as BSS
import qualified Data.ByteString.Lazy.Char8 as BS
import qualified Data.Proxy as Proxy
import qualified Data.Text as Text
import Network.HTTP.Media ((//), (/:))
import Servant
import qualified Types
import qualified Types.Api as ApiTypes
import qualified Types.Scenario as ScenarioTypes
import qualified Types.Template as TemplateTypes

api :: Proxy.Proxy API
api = Proxy.Proxy

type API =
  "api"
    :> ( "scenarios"
           :> Get '[JSON] [ScenarioTypes.Scenario]
           :<|> "scenario_detail"
           :> QueryParam' '[Required, Strict] "scenarioId" Integer
           :> QueryParam' '[Required, Strict] "year" Types.Year
           :> Get '[JSON] ApiTypes.ComparisonListData
           :<|> "scenario_detail_all_years"
           :> QueryParam' '[Required, Strict] "scenarioId" Integer
           :> QueryParam' '[Required, Strict] "year" Types.Year
           :> Get '[JSON] TemplateTypes.TemplateData
           :<|> "multi_scenario_comparison"
           :> QueryParams "scenarioId" Integer
           :> QueryParam' '[Required, Strict] "year" Types.Year
           :> Get '[JSON] [ApiTypes.ComparisonListData]
       )
    :<|> "app"
    :> ( "scenario_detail"
           :> Capture "scenario_id" Integer
           :> Capture "year" Types.Year
           :> Get '[Html] Text.Text
           :<|> "scenario_comparison"
           :> QueryParams "scenarioId" Integer
           :> QueryParams "year" Types.Year
           :> Get '[Html] Text.Text
           :<|> "scenario_detail_map"
           :> Capture "scenario_id" Integer
           :> Capture "metric_id" Integer
           :> Get '[Html] Text.Text
           --  :<|> "scenario_comparison_map"
           --    :> Capture "scenario_id_1" Integer
           --    :> Capture "scenario_id_2" Integer
           --    :> Capture "metric_id" Integer
           --    :> Capture "year" Types.Year
           --    :> Get '[Html] Text.Text
           :<|> Raw
       )
    :<|> "spatial"
    :> Capture "z" Int
    :> Capture "x" Int
    :> Capture "y" Text.Text
    :> Get '[OctetStream] BSS.ByteString

-- HTML content type with mimeRender instance
data Html

instance Accept Html where
  contentType _ = "text" // "html" /: ("charset", "utf-8")

instance MimeRender Html Text.Text where
  mimeRender _ val = BS.pack $ Text.unpack val
