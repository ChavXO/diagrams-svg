{-# LANGUAGE ConstraintKinds   #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes        #-}
{-# LANGUAGE ViewPatterns      #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Graphics.Rendering.SVG
-- Copyright   :  (c) 2011 diagrams-svg team (see LICENSE)
-- License     :  BSD-style (see LICENSE)
-- Maintainer  :  diagrams-discuss@googlegroups.com
--
-- Generic tools for generating SVG files.
--
-----------------------------------------------------------------------------

module Graphics.Rendering.SVG
    ( SVGFloat
    , svgHeader
    , renderPath
    , renderClip
    , renderText
    , renderDImage
    , renderDImageEmb
    , renderStyles
    , renderMiterLimit
    , renderFillTextureDefs
    , renderFillTexture
    , renderLineTextureDefs
    , renderLineTexture
    , dataUri
    , getNumAttr
    ) where

-- from base
import           Data.List                   (intercalate)
import qualified Data.Foldable as F
import           Data.Foldable (foldMap)

-- from lens
import           Control.Lens                hiding (transform)

-- from diagrams-core
import           Diagrams.Core.Transform     (matrixHomRep)

-- from diagrams-lib
import           Diagrams.Prelude            hiding (Attribute, Render, with, (<>))
import           Diagrams.TwoD.Path          (getFillRule)
import           Diagrams.TwoD.Text

import qualified Data.Text                   as T
import           Data.Monoid
import           Lucid.Svg                   hiding (renderText)

-- from blaze-svg
import           Text.Blaze.Svg11            (cr, hr, lr, m, mkPath, vr, (!))
import qualified Text.Blaze.Svg11            as S
import qualified Text.Blaze.Svg11.Attributes as A
import qualified Data.ByteString.Base64.Lazy as BS64
import qualified Data.ByteString.Lazy.Char8  as BS8

import           Codec.Picture

-- | Constaint on number type that diagrams-svg can use to render an SVG. This
--   includes the common number types: 'Double', 'Float'
type SVGFloat n = (Show n, TypeableFloat n, S.ToValue n)
-- Could we change Text.Blaze.SVG to use
--   showFFloat :: RealFloat a => Maybe Int -> a -> ShowS
-- or something similar for all numbers so we need TypeableFloat constraint.

toText :: Show a => a -> T.Text
toText = T.pack . show

getNumAttr :: AttributeClass (a n) => (a n -> t) -> Style v n -> Maybe t
getNumAttr f = (f <$>) . getAttr

-- | @svgHeader w h defs s@: @w@ width, @h@ height,
--   @defs@ global definitions for defs sections, @s@ actual SVG content.
svgHeader' :: SVGFloat n => n -> n -> [Attribute] -> Svg () -> Svg ()
svgHeader' w h defines s =  doctype_ <> with (svg11_ (g_ (defs_ defines s)))
  [ version_ "1.1"
  , width_    (toText w)
  , height_   (toText h)
  , fontSize_ "1"
  , viewBox_ (toText . unwords $ map show ([0, 0, round w, round h] :: [Int]))
  , stroke_ "rgb(0,0,0)"
  , strokeOpacity_ "1" ]

svgHeader :: SVGFloat n => n -> n -> Maybe S.Svg -> S.Svg -> S.Svg
svgHeader w h_ defines s =  S.docTypeSvg
  ! A.version "1.1"
  ! A.width    (S.toValue w)
  ! A.height   (S.toValue h_)
  ! A.fontSize "1"
  ! A.viewbox (S.toValue . unwords $ map show ([0, 0, round w, round h_] :: [Int]))
  ! A.stroke "rgb(0,0,0)"
  ! A.strokeOpacity "1"
  $ F.mapM_ S.defs defines >> S.g s

renderPath' :: SVGFloat n => Path V2 n -> Svg ()
renderPath' trs  = path_  [d_ makePath]
  where
    makePath = T.concat $ map renderTrail' (op Path trs)

renderPath :: SVGFloat n => Path V2 n -> S.Svg
renderPath trs  = S.path ! A.d makePath
  where
    makePath = mkPath $ mapM_ renderTrail (op Path trs)

renderTrail' :: SVGFloat n => Located (Trail V2 n) -> T.Text
renderTrail' (viewLoc -> (P (V2 x y), t)) = mR x y <> withTrail renderLine renderLoop t
  where
    renderLine = T.concat . map renderSeg' . lineSegments
    renderLoop lp =
      case loopSegments lp of
        -- let 'z' handle the last segment if it is linear
        (segs, Linear _) -> T.concat $ map renderSeg' segs

        -- otherwise we have to emit it explicitly
        _ -> T.concat $ map renderSeg' (lineSegments . cutLoop $ lp)
      <> z

renderTrail :: SVGFloat n => Located (Trail V2 n) -> S.Path
renderTrail (viewLoc -> (P (V2 x y), t)) = m x y >> withTrail renderLine renderLoop t
  where
    renderLine = mapM_ renderSeg . lineSegments
    renderLoop lp = do
      case loopSegments lp of
        -- let 'z' handle the last segment if it is linear
        (segs, Linear _) -> mapM_ renderSeg segs

        -- otherwise we have to emit it explicitly
        _ -> mapM_ renderSeg (lineSegments . cutLoop $ lp)
      S.z

renderSeg' :: SVGFloat n => Segment Closed V2 n -> T.Text
renderSeg' (Linear (OffsetClosed (V2 x 0))) = hR x
renderSeg' (Linear (OffsetClosed (V2 0 y))) = vR y
renderSeg' (Linear (OffsetClosed (V2 x y))) = lR x y
renderSeg' (Cubic  (V2 x0 y0)
                  (V2 x1 y1)
                  (OffsetClosed (V2 x2 y2))) = cR x0 y0 x1 y1 x2 y2

renderSeg :: SVGFloat n => Segment Closed V2 n -> S.Path
renderSeg (Linear (OffsetClosed (V2 x 0))) = hr x
renderSeg (Linear (OffsetClosed (V2 0 y))) = vr y
renderSeg (Linear (OffsetClosed (V2 x y))) = lr x y
renderSeg (Cubic  (V2 x0 y0)
                  (V2 x1 y1)
                  (OffsetClosed (V2 x2 y2))) = cr x0 y0 x1 y1 x2 y2

renderClip' :: SVGFloat n => Path V2 n -> Int -> Svg () -> Svg ()
renderClip' p ident svg =
  g_  [clipPath_ $ ("url(#" <> clipPathId ident <> ")")] $ do
    clippath_ [id_ (clipPathId ident)] (renderPath' p)
    svg
  where clipPathId i = "myClip" <> (toText i)

renderClip :: SVGFloat n => Path V2 n -> Int -> S.Svg -> S.Svg
renderClip p id_ svg =
  S.g ! A.clipPath (S.toValue $ "url(#" ++ clipPathId id_ ++ ")") $ do
    S.clippath ! A.id_ (S.toValue $ clipPathId id_) $ renderPath p
    svg
  where clipPathId i = "myClip" ++ show i

renderStop' :: SVGFloat n => GradientStop n -> Svg ()
renderStop' (GradientStop c v)
  = stop_ [ stopColor_ (colorToRgbText c)
          , offset_ (toText v)
          , stopOpacity_ (toText $ colorToOpacity c) ]

renderStop :: SVGFloat n => GradientStop n -> S.Svg
renderStop (GradientStop c v)
  = S.stop ! A.stopColor (S.toValue (colorToRgbString c))
           ! A.offset (S.toValue (show v))
           ! A.stopOpacity (S.toValue (colorToOpacity c))

spreadMethodText :: SpreadMethod -> T.Text
spreadMethodText GradPad      = "pad"
spreadMethodText GradReflect  = "reflect"
spreadMethodText GradRepeat   = "repeat"

spreadMethodStr :: SpreadMethod -> String
spreadMethodStr GradPad      = "pad"
spreadMethodStr GradReflect  = "reflect"
spreadMethodStr GradRepeat   = "repeat"

renderLinearGradient' :: SVGFloat n => LGradient n -> Int -> Svg ()
renderLinearGradient' g i = linearGradient_
    [ id_ (T.pack $ "gradient" ++ show i)
    , x1_  (toText x1)
    , y1_  (toText y1)
    , x2_  (toText x2)
    , y2_  (toText y2)
    , gradientTransform_ mx
    , gradientUnits_ "userSpaceOnUse"
    , spreadMethod_ (spreadMethodText (g^.lGradSpreadMethod)) ]
    ( foldMap renderStop' (g^.lGradStops) )
  where
    mx = matrix a1 a2 b1 b2 c1 c2
    [[a1, a2], [b1, b2], [c1, c2]] = matrixHomRep (g^.lGradTrans)
    P (V2 x1 y1) = g ^. lGradStart
    P (V2 x2 y2) = g ^. lGradEnd

renderLinearGradient :: SVGFloat n => LGradient n -> Int -> S.Svg
renderLinearGradient g i = S.lineargradient
    ! A.id_ (S.toValue ("gradient" ++ show i))
    ! A.x1  (S.toValue x1)
    ! A.y1  (S.toValue y1)
    ! A.x2  (S.toValue x2)
    ! A.y2  (S.toValue y2)
    ! A.gradienttransform (S.toValue matrix)
    ! A.gradientunits "userSpaceOnUse"
    ! A.spreadmethod (S.toValue (spreadMethodStr (g^.lGradSpreadMethod)))
    $ foldMap renderStop (g^.lGradStops)
  where
    matrix = S.matrix a1 a2 b1 b2 c1 c2
    [[a1, a2], [b1, b2], [c1, c2]] = matrixHomRep (g^.lGradTrans)
    P (V2 x1 y1) = g ^. lGradStart
    P (V2 x2 y2) = g ^. lGradEnd

renderRadialGradient' :: SVGFloat n => RGradient n -> Int -> Svg ()
renderRadialGradient' g i = radialGradient_
    [ id_ (T.pack $ "gradient" ++ show i)
    , r_ (toText (g^.rGradRadius1))
    , cx_ (toText cx')
    , cy_ (toText cy')
    , fx_ (toText fx')
    , fy_ (toText fy')
    , gradientTransform_ mx
    , gradientUnits_ "userSpaceOnUse"
    , spreadMethod_ (spreadMethodText (g^.rGradSpreadMethod)) ]
    ( foldMap renderStop' ss )
  where
    mx = matrix a1 a2 b1 b2 c1 c2
    [[a1, a2], [b1, b2], [c1, c2]] = matrixHomRep (g^.rGradTrans)
    P (V2 cx' cy') = g ^. rGradCenter1
    P (V2 fx' fy') = g ^. rGradCenter0 -- SVG's focal point is our inner center.

    -- Adjust the stops so that the gradient begins at the perimeter of
    -- the inner circle (center0, radius0) and ends at the outer circle.
    r0 = g^.rGradRadius0
    r1 = g^.rGradRadius1
    stopFracs = r0 / r1 : map (\s -> (r0 + (s^.stopFraction) * (r1 - r0)) / r1)
                (g^.rGradStops)
    gradStops = case g^.rGradStops of
      []       -> []
      xs@(x:_) -> x : xs
    ss = zipWith (\gs sf -> gs & stopFraction .~ sf ) gradStops stopFracs

renderRadialGradient :: SVGFloat n => RGradient n -> Int -> S.Svg
renderRadialGradient g i = S.radialgradient
    ! A.id_ (S.toValue ("gradient" ++ show i))
    ! A.r (S.toValue (g^.rGradRadius1))
    ! A.cx (S.toValue cx')
    ! A.cy (S.toValue cy')
    ! A.fx (S.toValue fx')
    ! A.fy (S.toValue fy')
    ! A.gradienttransform (S.toValue matrix)
    ! A.gradientunits "userSpaceOnUse"
    ! A.spreadmethod (S.toValue (spreadMethodStr (g^.rGradSpreadMethod)))
    $ foldMap renderStop ss
  where
    matrix = S.matrix a1 a2 b1 b2 c1 c2
    [[a1, a2], [b1, b2], [c1, c2]] = matrixHomRep (g^.rGradTrans)
    P (V2 cx' cy') = g ^. rGradCenter1
    P (V2 fx' fy') = g ^. rGradCenter0 -- SVG's focal point is our inner center.

    -- Adjust the stops so that the gradient begins at the perimeter of
    -- the inner circle (center0, radius0) and ends at the outer circle.
    r0 = g^.rGradRadius0
    r1 = g^.rGradRadius1
    stopFracs = r0 / r1 : map (\s -> (r0 + (s^.stopFraction) * (r1 - r0)) / r1)
                (g^.rGradStops)
    gradStops = case g^.rGradStops of
      []       -> []
      xs@(x:_) -> x : xs
    ss = zipWith (\gs sf -> gs & stopFraction .~ sf ) gradStops stopFracs

-- Create a gradient element so that it can be used as an attribute value for fill.
renderFillTextureDefs' :: SVGFloat n => Int -> Style v n -> Svg ()
renderFillTextureDefs' i s =
  case getNumAttr getFillTexture s of
    Just (LG g) -> renderLinearGradient' g i
    Just (RG g) -> renderRadialGradient' g i
    _           -> mempty

renderFillTextureDefs :: SVGFloat n => Int -> Style v n -> S.Svg
renderFillTextureDefs i s =
  case getNumAttr getFillTexture s of
    Just (LG g) -> renderLinearGradient g i
    Just (RG g) -> renderRadialGradient g i
    _           -> mempty

-- Render the gradient using the id set up in renderFillTextureDefs.
renderFillTexture' :: SVGFloat n => Int -> Style v n -> [Attribute]
renderFillTexture' ident s = case getNumAttr getFillTexture s of
  Just (SC (SomeColor c)) -> renderAttr' fill_ fillColorRgb <>
                             renderAttr' fillOpacity_ fillColorOpacity
    where
      fillColorRgb     = Just $ colorToRgbText c
      fillColorOpacity = Just $ colorToOpacity c
  Just (LG _) -> [fill_ ("url(#gradient" <> toText ident <> ")"), fillOpacity_ "1"]
  Just (RG _) -> [fill_ ("url(#gradient" <> toText ident <> ")"), fillOpacity_ "1"]
  Nothing     -> []

renderFillTexture :: SVGFloat n => Int -> Style v n -> S.Attribute
renderFillTexture id_ s = case getNumAttr getFillTexture s of
  Just (SC (SomeColor c)) -> renderAttr A.fill fillColorRgb `mappend`
                             renderAttr A.fillOpacity fillColorOpacity
    where
      fillColorRgb     = Just $ colorToRgbString c
      fillColorOpacity = Just $ colorToOpacity c
  Just (LG _) -> A.fill (S.toValue ("url(#gradient" ++ show id_ ++ ")"))
                `mappend` A.fillOpacity "1"
  Just (RG _) -> A.fill (S.toValue ("url(#gradient" ++ show id_ ++ ")"))
                `mappend` A.fillOpacity "1"
  Nothing     -> mempty

renderLineTextureDefs' :: SVGFloat n => Int -> Style v n -> Svg ()
renderLineTextureDefs' i s =
  case getNumAttr getLineTexture s of
    Just (LG g) -> renderLinearGradient' g i
    Just (RG g) -> renderRadialGradient' g i
    _           -> mempty

renderLineTextureDefs :: SVGFloat n => Int -> Style v n -> S.Svg
renderLineTextureDefs i s =
  case getNumAttr getLineTexture s of
    Just (LG g) -> renderLinearGradient g i
    Just (RG g) -> renderRadialGradient g i
    _           -> mempty

renderLineTexture' :: SVGFloat n => Int -> Style v n -> [Attribute]
renderLineTexture' ident s = case getNumAttr getLineTexture s of
  Just (SC (SomeColor c)) -> renderAttr' stroke_ lineColorRgb <>
                             renderAttr' strokeOpacity_ lineColorOpacity
    where
      lineColorRgb     = Just $ colorToRgbText c
      lineColorOpacity = Just $ colorToOpacity c
  Just (LG _) -> [stroke_ ("url(#gradient" <> toText ident <> ")"), strokeOpacity_ "1"]
  Just (RG _) -> [stroke_ ("url(#gradient" <> toText ident <> ")"), strokeOpacity_ "1"]
  Nothing     -> []

renderLineTexture :: SVGFloat n => Int -> Style v n -> S.Attribute
renderLineTexture id_ s = case getNumAttr getLineTexture s of
  Just (SC (SomeColor c)) -> renderAttr A.stroke lineColorRgb `mappend`
                             renderAttr A.strokeOpacity lineColorOpacity
    where
      lineColorRgb     = Just $ colorToRgbString c
      lineColorOpacity = Just $ colorToOpacity c
  Just (LG _) -> A.stroke (S.toValue ("url(#gradient" ++ show id_ ++ ")"))
                `mappend` A.strokeOpacity "1"
  Just (RG _) -> A.stroke (S.toValue ("url(#gradient" ++ show id_ ++ ")"))
                `mappend` A.strokeOpacity "1"
  Nothing     -> mempty

dataUri' :: String -> BS8.ByteString -> T.Text
dataUri' mime dat = T.pack $ "data:"++mime++";base64," ++ BS8.unpack (BS64.encode dat)

dataUri :: String -> BS8.ByteString -> String
dataUri mime dat = "data:"++mime++";base64," ++ BS8.unpack (BS64.encode dat)

renderDImageEmb' :: SVGFloat n => DImage n Embedded -> Svg ()
renderDImageEmb' di@(DImage (ImageRaster dImg) _ _ _) =
  renderDImage' di $ dataUri' "image/png" img
  where
    img = case encodeDynamicPng dImg of
            Left str   -> error str
            Right img' -> img'

renderDImageEmb :: SVGFloat n => DImage n Embedded -> S.Svg
renderDImageEmb di@(DImage (ImageRaster dImg) _ _ _) =
  renderDImage di $ dataUri "image/png" img
  where
    img = case encodeDynamicPng dImg of
            Left str   -> error str
            Right img' -> img'

renderDImage' :: SVGFloat n => DImage n any -> T.Text -> Svg ()
renderDImage' (DImage _ w h tr) uridata =
  image_
    [ transform_ transformMatrix
    , width_ (toText w)
    , height_ (toText h)
    , xlinkHref_ uridata ]
  where
    [[a,b],[c,d],[e,f]] = matrixHomRep (tr `mappend` reflectionY
                                           `mappend` tX `mappend` tY)
    transformMatrix = matrix a b c d e f
    tX = translationX $ fromIntegral (-w)/2
    tY = translationY $ fromIntegral (-h)/2

renderDImage :: SVGFloat n => DImage n any -> String -> S.Svg
renderDImage (DImage _ w h tr) uridata =
  S.image
    ! A.transform transformMatrix
    ! A.width (S.toValue w)
    ! A.height (S.toValue h)
    ! A.xlinkHref (S.preEscapedToValue uridata)
  where
    [[a,b],[c,d],[e,f]] = matrixHomRep (tr `mappend` reflectionY
                                           `mappend` tX `mappend` tY)
    transformMatrix = S.matrix a b c d e f
    tX = translationX $ fromIntegral (-w)/2
    tY = translationY $ fromIntegral (-h)/2

-- XXX Why can't ghc infer this type? and why does it even work.
-- In fact both `Svg ()`s can be replaced with an arbitrary type variable say `s`
-- and it still works.
-- https://github.com/chrisdone/lucid/blob/master/src/Lucid/Base.hs#L181
renderText' :: (SVGFloat n, Term [Attribute] (T.Text -> Svg ())) => Text n -> Svg ()
renderText' (Text tt tAlign str) =
  text_
    [ transform_ transformMatrix
    , dominantBaseline_ vAlign
    , textAnchor_ hAlign
    , stroke_ "none" ]
    (T.pack str)
 where
  vAlign = case tAlign of
             BaselineText -> "alphabetic"
             BoxAlignedText _ h -> case h of -- A mere approximation
               h' | h' <= 0.25 -> "text-after-edge"
               h' | h' >= 0.75 -> "text-before-edge"
               _ -> "middle"
  hAlign = case tAlign of
             BaselineText -> "start"
             BoxAlignedText w _ -> case w of -- A mere approximation
               w' | w' <= 0.25 -> "start"
               w' | w' >= 0.75 -> "end"
               _ -> "middle"
  t                   = tt `mappend` reflectionY
  [[a,b],[c,d],[e,f]] = matrixHomRep t
  transformMatrix     = matrix a b c d e f

renderText :: SVGFloat n => Text n -> S.Svg
renderText (Text tt tAlign str) =
  S.text_
    ! A.transform transformMatrix
    ! A.dominantBaseline vAlign
    ! A.textAnchor hAlign
    ! A.stroke "none" $
      S.toMarkup str
 where
  vAlign = case tAlign of
             BaselineText -> "alphabetic"
             BoxAlignedText _ h -> case h of -- A mere approximation
               h' | h' <= 0.25 -> "text-after-edge"
               h' | h' >= 0.75 -> "text-before-edge"
               _ -> "middle"
  hAlign = case tAlign of
             BaselineText -> "start"
             BoxAlignedText w _ -> case w of -- A mere approximation
               w' | w' <= 0.25 -> "start"
               w' | w' >= 0.75 -> "end"
               _ -> "middle"
  t                   = tt `mappend` reflectionY
  [[a,b],[c,d],[e,f]] = matrixHomRep t
  transformMatrix     = S.matrix a b c d e f

renderStyles' :: SVGFloat n => Int -> Int -> Style v n -> [Attribute]
renderStyles' fillId lineId s = concatMap ($ s) $
  [ renderLineTexture' lineId
  , renderFillTexture' fillId
  , renderLineWidth'
  , renderLineCap'
  , renderLineJoin'
  , renderFillRule'
  , renderDashing'
  , renderOpacity'
  , renderFontSize'
  , renderFontSlant'
  , renderFontWeight'
  , renderFontFamily'
  , renderMiterLimit'
  ]

renderStyles :: SVGFloat n => Int -> Int -> Style v n -> S.Attribute
renderStyles fillId lineId s = mconcat . map ($ s) $
  [ renderLineTexture lineId
  , renderFillTexture fillId
  , renderLineWidth
  , renderLineCap
  , renderLineJoin
  , renderFillRule
  , renderDashing
  , renderOpacity
  , renderFontSize
  , renderFontSlant
  , renderFontWeight
  , renderFontFamily
  , renderMiterLimit
  ]

renderMiterLimit' :: SVGFloat n => Style v n -> [Attribute]
renderMiterLimit' s = renderAttr' strokeMiterlimit_ miterLimit
 where miterLimit = getLineMiterLimit <$> getAttr s

renderMiterLimit :: SVGFloat n => Style v n -> S.Attribute
renderMiterLimit s = renderAttr A.strokeMiterlimit miterLimit
 where miterLimit = getLineMiterLimit <$> getAttr s

renderOpacity' :: SVGFloat n => Style v n -> [Attribute]
renderOpacity' s = renderAttr' opacity_ o
 where o = getOpacity <$> getAttr s

renderOpacity :: SVGFloat n => Style v n -> S.Attribute
renderOpacity s = renderAttr A.opacity opacity_
 where opacity_ = getOpacity <$> getAttr s

renderFillRule' :: SVGFloat n => Style v n -> [Attribute]
renderFillRule' s = renderAttr' fillRule_ fr
  where fr = (fillRuleToText . getFillRule) <$> getAttr s
        fillRuleToText :: FillRule -> T.Text
        fillRuleToText Winding = "nonzero"
        fillRuleToText EvenOdd = "evenodd"

renderFillRule :: SVGFloat n => Style v n -> S.Attribute
renderFillRule s = renderAttr A.fillRule fillRule_
  where fillRule_ = (fillRuleToStr . getFillRule) <$> getAttr s
        fillRuleToStr :: FillRule -> String
        fillRuleToStr Winding = "nonzero"
        fillRuleToStr EvenOdd = "evenodd"

renderLineWidth' :: SVGFloat n => Style v n -> [Attribute]
renderLineWidth' s = renderAttr' strokeWidth_ lineWidth'
  where lineWidth' = getNumAttr getLineWidth s

renderLineWidth :: SVGFloat n => Style v n -> S.Attribute
renderLineWidth s = renderAttr A.strokeWidth lineWidth'
  where lineWidth' = getNumAttr getLineWidth s


renderLineCap' :: SVGFloat n => Style v n -> [Attribute]
renderLineCap' s = renderAttr' strokeLinecap_ lc
  where lc = (lineCapToText . getLineCap) <$> getAttr s
        lineCapToText :: LineCap -> T.Text
        lineCapToText LineCapButt   = "butt"
        lineCapToText LineCapRound  = "round"
        lineCapToText LineCapSquare = "square"

renderLineCap :: SVGFloat n => Style v n -> S.Attribute
renderLineCap s = renderAttr A.strokeLinecap lineCap_
  where lineCap_ = (lineCapToStr . getLineCap) <$> getAttr s
        lineCapToStr :: LineCap -> String
        lineCapToStr LineCapButt   = "butt"
        lineCapToStr LineCapRound  = "round"
        lineCapToStr LineCapSquare = "square"

renderLineJoin' :: SVGFloat n => Style v n -> [Attribute]
renderLineJoin' s = renderAttr' strokeLinejoin_ lj
  where lj = (lineJoinToText . getLineJoin) <$> getAttr s
        lineJoinToText :: LineJoin -> T.Text
        lineJoinToText LineJoinMiter = "miter"
        lineJoinToText LineJoinRound = "round"
        lineJoinToText LineJoinBevel = "bevel"

renderLineJoin :: SVGFloat n => Style v n -> S.Attribute
renderLineJoin s = renderAttr A.strokeLinejoin lineJoin_
  where lineJoin_ = (lineJoinToStr . getLineJoin) <$> getAttr s
        lineJoinToStr :: LineJoin -> String
        lineJoinToStr LineJoinMiter = "miter"
        lineJoinToStr LineJoinRound = "round"
        lineJoinToStr LineJoinBevel = "bevel"

renderDashing' :: SVGFloat n => Style v n -> [Attribute]
renderDashing' s = renderAttr' strokeDasharray_ arr <>
                   renderAttr' strokeDashoffset_ dOffset
 where
  getDasharray  (Dashing a _) = a
  getDashoffset (Dashing _ o) = o
  dashArrayToStr              = intercalate "," . map show
  dashing_                    = getNumAttr getDashing s
  arr                         = (dashArrayToStr . getDasharray) <$> dashing_
  dOffset                     = getDashoffset <$> dashing_

renderDashing :: SVGFloat n => Style v n -> S.Attribute
renderDashing s = renderAttr A.strokeDasharray arr `mappend`
                  renderAttr A.strokeDashoffset dOffset
 where
  getDasharray  (Dashing a _) = a
  getDashoffset (Dashing _ o) = o
  dashArrayToStr              = intercalate "," . map show
  dashing_                    = getNumAttr getDashing s
  arr                         = (dashArrayToStr . getDasharray) <$> dashing_
  dOffset                     = getDashoffset <$> dashing_

renderFontSize' :: SVGFloat n => Style v n -> [Attribute]
renderFontSize' s = renderAttr' fontSize_ fs
 where
  fs = getNumAttr ((++ "px") . show . getFontSize) s

renderFontSize :: SVGFloat n => Style v n -> S.Attribute
renderFontSize s = renderAttr A.fontSize fontSize_
 where
  fontSize_ = getNumAttr ((++ "px") . show . getFontSize) s

renderFontSlant' :: SVGFloat n => Style v n -> [Attribute]
renderFontSlant' s = renderAttr' fontStyle_ fs
 where
  fs = (fontSlantAttr . getFontSlant) <$> getAttr s
  fontSlantAttr :: FontSlant -> T.Text
  fontSlantAttr FontSlantItalic  = "italic"
  fontSlantAttr FontSlantOblique = "oblique"
  fontSlantAttr FontSlantNormal  = "normal"

renderFontSlant :: SVGFloat n => Style v n -> S.Attribute
renderFontSlant s = renderAttr A.fontStyle fontSlant_
 where
  fontSlant_ = (fontSlantAttr . getFontSlant) <$> getAttr s
  fontSlantAttr :: FontSlant -> String
  fontSlantAttr FontSlantItalic  = "italic"
  fontSlantAttr FontSlantOblique = "oblique"
  fontSlantAttr FontSlantNormal  = "normal"

renderFontWeight' :: SVGFloat n => Style v n -> [Attribute]
renderFontWeight' s = renderAttr' fontWeight_ fw
 where
  fw = (fontWeightAttr . getFontWeight) <$> getAttr s
  fontWeightAttr :: FontWeight -> T.Text
  fontWeightAttr FontWeightNormal = "normal"
  fontWeightAttr FontWeightBold   = "bold"

renderFontWeight :: SVGFloat n => Style v n -> S.Attribute
renderFontWeight s = renderAttr A.fontWeight fontWeight_
 where
  fontWeight_ = (fontWeightAttr . getFontWeight) <$> getAttr s
  fontWeightAttr :: FontWeight -> String
  fontWeightAttr FontWeightNormal = "normal"
  fontWeightAttr FontWeightBold   = "bold"

renderFontFamily' :: SVGFloat n => Style v n -> [Attribute]
renderFontFamily' s = renderAttr' fontFamily_ ff
 where
  ff = getFont <$> getAttr s

renderFontFamily :: SVGFloat n => Style v n -> S.Attribute
renderFontFamily s = renderAttr A.fontFamily fontFamily_
 where
  fontFamily_ = getFont <$> getAttr s

-- | Render a style attribute if available, empty otherwise.
renderAttr' :: Show s => (T.Text -> Attribute)
           -> Maybe s
           -> [Attribute]
renderAttr' attr valM = case valM of
  Just val -> [attr (toText val)]
  Nothing  -> []
  
renderAttr :: S.ToValue s => (S.AttributeValue -> S.Attribute)
           -> Maybe s
           -> S.Attribute
renderAttr attr valM = case valM of
  Just val -> attr (S.toValue val)
  Nothing  -> mempty

colorToRgbText :: forall c . Color c => c -> T.Text
colorToRgbText c = T.concat
  [ "rgb("
  , int r, ","
  , int g, ","
  , int b
  , ")"
  ]
 where int d = toText (round (d * 255) :: Int)
       (r,g,b,_) = colorToSRGBA c

colorToRgbString :: forall c . Color c => c -> String
colorToRgbString c = concat
  [ "rgb("
  , int r, ","
  , int g, ","
  , int b
  , ")"
  ]
 where int d = show (round (d * 255) :: Int)
       (r,g,b,_) = colorToSRGBA c

colorToOpacity :: forall c . Color c => c -> Double
colorToOpacity c = a
 where (_,_,_,a) = colorToSRGBA c
