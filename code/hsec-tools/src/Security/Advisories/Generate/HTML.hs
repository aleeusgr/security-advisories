{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Security.Advisories.Generate.HTML
  ( renderAdvisoriesIndex,
  )
where

import Control.Monad (forM_)
import Control.Monad.Extra (mapMaybeM)
import Data.Either.Extra (eitherToMaybe)
import Data.List (isPrefixOf, isSuffixOf, sortOn)
import Data.List.Extra (groupSort)
import qualified Data.Map.Strict as Map
import Data.Ord (Down (..))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Lucid
import Security.Advisories (AttributeOverridePolicy (NoOverrides), OutOfBandAttributes(..), parseAdvisory, emptyOutOfBandAttributes)
import Data.Functor((<&>))
import Security.Advisories.Git
import qualified Security.Advisories as Advisories
import System.Directory (createDirectoryIfMissing)
import System.Directory.Extra (listFilesRecursive)
import System.FilePath (takeFileName, (</>))

{-
TODO
* Generate advisories page
* Select head menu
-}

-- * Actions

renderAdvisoriesIndex :: FilePath -> FilePath -> IO ()
renderAdvisoriesIndex src dst = do
  let isAdvisory p =
        let fileName = takeFileName p
        in isPrefixOf "HSEC-" fileName && isSuffixOf ".md" fileName
      readAdvisory path = do
        oob <-
          getAdvisoryGitInfo path <&> \case
            Left _ -> emptyOutOfBandAttributes
            Right gitInfo -> emptyOutOfBandAttributes
              { oobPublished = Just (firstAppearanceCommitDate gitInfo)
              , oobModified = Just (lastModificationCommitDate gitInfo)
              }
        fileContent <- T.readFile path
        return $ eitherToMaybe $ parseAdvisory NoOverrides oob fileContent
  advisoriesFileName <- filter isAdvisory <$> listFilesRecursive src
  advisories <- map toAdvisoryR <$> mapMaybeM readAdvisory advisoriesFileName

  createDirectoryIfMissing False dst
  renderToFile (dst </> "by-dates.html") $ listByDates advisories
  renderToFile (dst </> "by-packages.html") $ listByPackages advisories
  return ()

-- * Rendering types

data AdvisoryR = AdvisoryR
  { advisoryId :: Text,
    advisorySummary :: Text,
    advisoryAffected :: [AffectedPackageR]
  }
  deriving stock (Eq, Show)

data AffectedPackageR = AffectedPackageR
  { packageName :: Text,
    introduced :: Text,
    fixed :: Maybe Text
  }
  deriving stock (Eq, Show)

-- * Pages

listByDates :: [AdvisoryR] -> Html ()
listByDates advisories =
  inPage $
    div_ [class_ "pure-u-1"] $ do
      div_ [class_ "advisories"] $ do
        table_ [class_ "pure-table pure-table-horizontal"] $ do
          thead_ $ do
            tr_ $ do
              th_ "#"
              th_ "Package(s)"
              th_ "Summary"

          tbody_ $ do
            let sortedAdvisories =
                  zip
                    (sortOn (Down . (.advisoryId)) advisories)
                    (cycle [[], [class_ "pure-table-odd"]])
            forM_ sortedAdvisories $ \(advisory, trClasses) ->
              tr_ trClasses $ do
                td_ [class_ "advisory-id"] $ a_ [href_ "#"] $ toHtml advisory.advisoryId
                td_ [class_ "advisory-packages"] $ toHtml $ T.intercalate "," $ (.packageName) <$> advisory.advisoryAffected
                td_ [class_ "advisory-summary"] $ toHtml advisory.advisorySummary

listByPackages :: [AdvisoryR] -> Html ()
listByPackages advisories =
  inPage $ do
    div_ [class_ "pure-u-1"] $ do
      let byPackage :: Map.Map Text [(AdvisoryR, AffectedPackageR)]
          byPackage =
            Map.fromList $
              groupSort
                [ (package.packageName, (advisory, package))
                  | advisory <- advisories,
                    package <- advisory.advisoryAffected
                ]

      forM_ (Map.toList byPackage) $ \(currentPackageName, perPackageAdvisory) -> do
        h2_ $ toHtml currentPackageName
        div_ [class_ "advisories"] $ do
          table_ [class_ "pure-table pure-table-horizontal"] $ do
            thead_ $ do
              tr_ $ do
                th_ "#"
                th_ "Introduced"
                th_ "Fixed"
                th_ "Summary"

            tbody_ $ do
              let sortedAdvisories =
                    zip
                      (sortOn (Down . (.advisoryId) . fst) perPackageAdvisory)
                      (cycle [[], [class_ "pure-table-odd"]])
              forM_ sortedAdvisories $ \((advisory, package), trClasses) ->
                tr_ trClasses $ do
                  td_ [class_ "advisory-id"] $ a_ [href_ "#"] $ toHtml advisory.advisoryId
                  td_ [class_ "advisory-introduced"] $ toHtml package.introduced
                  td_ [class_ "advisory-fixed"] $ maybe (return ()) toHtml package.fixed
                  td_ [class_ "advisory-summary"] $ toHtml advisory.advisorySummary

-- * Utils

inPage :: Html () -> Html ()
inPage content =
  doctypehtml_ $
    html_ $ do
      head_ $ do
        meta_ [charset_ "UTF-8"]
        link_ [rel_ "stylesheet", href_ "https://cdn.jsdelivr.net/npm/purecss@3.0.0/build/pure-min.css", integrity_ "sha384-X38yfunGUhNzHpBaEBsWLO+A0HDYOQi8ufWDkZ0k9e0eXz/tH3II7uKZ9msv++Ls", crossorigin_ "anonymous"]
        meta_ [name_ "viewport", content_ "width=device-width, initial-scale=1"]
        title_ "Haskell Security Advisories"
        style_ $
          T.intercalate
            "\n"
            [ ".advisories, .content {",
              "    margin: 1em;",
              "}",
              "a {",
              "    text-decoration: none;",
              "}",
              "a:visited {",
              "    text-decoration: none;",
              "    color: darkblue;",
              "}"
            ]
      body_ $ do
        div_ [class_ "pure-u-1"] $ do
          div_ [class_ "pure-menu pure-menu-horizontal"] $ do
            span_ [class_ "pure-menu-heading pure-menu-link"] "Advisories list"
            ul_ [class_ "pure-menu-list"] $ do
              li_ [class_ "pure-menu-item"] $
                a_ [href_ "#", class_ "pure-menu-link"] "by date"
              li_ [class_ "pure-menu-item"] $
                a_ [href_ "#", class_ "pure-menu-link"] "by package"
        div_ [class_ "content"] content

toAdvisoryR :: Advisories.Advisory -> AdvisoryR
toAdvisoryR x =
  AdvisoryR
    { advisoryId = x.advisoryId,
      advisorySummary = x.advisorySummary,
      advisoryAffected = concatMap toAffectedPackageR x.advisoryAffected
    }
  where
    toAffectedPackageR :: Advisories.Affected -> [AffectedPackageR]
    toAffectedPackageR p =
      flip map p.affectedVersions $ \versionRange ->
        AffectedPackageR
          { packageName = p.affectedPackage,
            introduced = versionRange.affectedVersionRangeIntroduced,
            fixed = versionRange.affectedVersionRangeFixed
          }