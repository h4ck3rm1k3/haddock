--
-- Haddock - A Haskell Documentation Tool
--
-- (c) Simon Marlow 2003
--

module HaddockHtml ( 
	ppHtml, copyHtmlBits, 
	ppHtmlIndex, ppHtmlContents,
	ppHtmlHelpFiles
  ) where

import Prelude hiding (div)
import HaddockVersion
import HaddockTypes
import HaddockUtil
import HaddockModuleTree
import HaddockHH
import HaddockHH2
import HaddockDevHelp
import HsSyn
import Map ( Map )
import qualified Map

import Maybe	( fromJust, isJust, mapMaybe )
import List 	( sortBy )
import Char	( isUpper, toUpper )
import Monad	( when, unless )


import Foreign
import Control.Exception ( handle, bracket )

import Binary    ( openBinaryFile )
import System.IO ( IOMode(..), hClose, hGetBuf, hPutBuf )

import Html
import qualified Html

-- -----------------------------------------------------------------------------
-- Generating HTML documentation

ppHtml	:: String
	-> Maybe String				-- package
	-> Maybe String
	-> [(Module, Interface)]
	-> FilePath			-- destination directory
	-> Maybe Doc			-- prologue text, maybe
	-> Maybe String		-- the Html Help format (--html-help)
	-> Maybe String			-- the contents URL (--use-contents)
	-> Maybe String			-- the index URL (--use-index)
	-> IO ()

ppHtml doctitle maybe_package source_url ifaces odir prologue maybe_html_help_format
	maybe_contents_url maybe_index_url =  do
  let
	visible_ifaces = filter visible ifaces
	visible (_, i) = OptHide `notElem` iface_options i

  when (not (isJust maybe_contents_url)) $ 
    ppHtmlContents odir doctitle maybe_package maybe_html_help_format maybe_index_url 
	[ (m,iface{iface_package=Nothing}) | (m,iface) <- visible_ifaces ]
	-- we don't want to display the packages in a single-package contents
	prologue

  when (not (isJust maybe_index_url)) $ 
    ppHtmlIndex odir doctitle maybe_package maybe_html_help_format maybe_contents_url visible_ifaces
    
  when (not (isJust maybe_contents_url && isJust maybe_index_url)) $ 
	ppHtmlHelpFiles doctitle maybe_package ifaces odir maybe_html_help_format []

  mapM_ (ppHtmlModule odir doctitle source_url 
	   maybe_contents_url maybe_index_url) visible_ifaces

ppHtmlHelpFiles	
    :: String                   -- doctitle
    -> Maybe String				-- package
	-> [(Module, Interface)]
	-> FilePath                 -- destination directory
	-> Maybe String             -- the Html Help format (--html-help)
	-> [FilePath]               -- external packages paths
	-> IO ()
ppHtmlHelpFiles doctitle maybe_package ifaces odir maybe_html_help_format pkg_paths =  do
  let
	visible_ifaces = filter visible ifaces
	visible (_, i) = OptHide `notElem` iface_options i

  -- Generate index and contents page for Html Help if requested
  case maybe_html_help_format of
    Nothing        -> return ()
    Just "mshelp"  -> ppHHProject odir doctitle maybe_package visible_ifaces pkg_paths
    Just "mshelp2" -> do
		ppHH2Files      odir maybe_package visible_ifaces pkg_paths
		ppHH2Collection odir doctitle maybe_package
    Just "devhelp" -> ppDevHelpFile odir doctitle maybe_package visible_ifaces
    Just format    -> fail ("The "++format++" format is not implemented")

copyFile :: FilePath -> FilePath -> IO ()
copyFile fromFPath toFPath =
	(bracket (openBinaryFile fromFPath ReadMode) hClose $ \hFrom ->
	 bracket (openBinaryFile toFPath WriteMode) hClose $ \hTo ->
	 allocaBytes bufferSize $ \buffer ->
		copyContents hFrom hTo buffer)
	where
		bufferSize = 1024
		
		copyContents hFrom hTo buffer = do
			count <- hGetBuf hFrom buffer bufferSize
			when (count > 0) $ do
				hPutBuf hTo buffer count
				copyContents hFrom hTo buffer


copyHtmlBits :: FilePath -> FilePath -> Maybe FilePath -> IO ()
copyHtmlBits odir libdir maybe_css = do
  let 
	css_file = case maybe_css of
			Nothing -> pathJoin [libdir, cssFile]
			Just f  -> f
	css_destination = pathJoin [odir, cssFile]
	copyLibFile f = do
	   copyFile (pathJoin [libdir, f]) (pathJoin [odir, f])
 
  copyFile css_file css_destination
  mapM_ copyLibFile [ iconFile, plusFile, minusFile, jsFile ]

footer :: HtmlTable
footer = 
  tda [theclass "botbar"] << 
	( toHtml "Produced by" <+> 
	  (anchor ! [href projectUrl] << toHtml projectName) <+>
	  toHtml ("version " ++ projectVersion)
	)
   

src_button :: Maybe String -> String -> String -> HtmlTable
src_button source_url _ file
  | Just u <- source_url = 
	let src_url = if (last u == '/') then u ++ file else u ++ '/':file
	in
	topButBox (anchor ! [href src_url] << toHtml "Source code")
  | otherwise =
	Html.emptyTable
  
contentsButton :: Maybe String -> HtmlTable
contentsButton maybe_contents_url 
  = topButBox (anchor ! [href url] << toHtml "Contents")
  where url = case maybe_contents_url of
			Nothing -> contentsHtmlFile
			Just url -> url

indexButton :: Maybe String -> HtmlTable
indexButton maybe_index_url 
  = topButBox (anchor ! [href url] << toHtml "Index")
  where url = case maybe_index_url of
			Nothing -> indexHtmlFile
			Just url -> url

simpleHeader :: String -> Maybe String -> Maybe String -> HtmlTable
simpleHeader doctitle maybe_contents_url maybe_index_url = 
  (tda [theclass "topbar"] << 
     vanillaTable << (
       (td << 
  	image ! [src "haskell_icon.gif", width "16", height 16, alt " " ]
       ) <->
       (tda [theclass "title"] << toHtml doctitle) <->
	contentsButton maybe_contents_url <-> indexButton maybe_index_url
   ))

pageHeader :: String -> Interface -> String
    -> Maybe String -> Maybe String -> Maybe String -> HtmlTable
pageHeader mdl iface doctitle source_url maybe_contents_url maybe_index_url =
  (tda [theclass "topbar"] << 
    vanillaTable << (
       (td << 
  	image ! [src "haskell_icon.gif", width "16", height 16, alt " "]
       ) <->
       (tda [theclass "title"] << toHtml doctitle) <->
	src_button source_url mdl (iface_filename iface) <->
	contentsButton maybe_contents_url <->
	indexButton maybe_index_url
    )
   ) </>
   tda [theclass "modulebar"] <<
	(vanillaTable << (
	  (td << font ! [size "6"] << toHtml mdl) <->
	  moduleInfo iface
	)
    )

moduleInfo :: Interface -> HtmlTable
moduleInfo iface = 
   let
      info = iface_info iface

      doOneEntry :: (String,ModuleInfo -> Maybe String) -> Maybe HtmlTable
      doOneEntry (fieldName,field) = case field info of
         Nothing -> Nothing
         Just fieldValue -> 
            Just ((tda [theclass "infohead"] << toHtml fieldName)
               <-> (tda [theclass "infoval"]) << toHtml fieldValue)
     
      entries :: [HtmlTable]
      entries = mapMaybe doOneEntry [
         ("Portability",portability),
         ("Stability",stability),
         ("Maintainer",maintainer)
         ]
   in
      case entries of
         [] -> Html.emptyTable
         _ -> tda [align "right"] << narrowTable << (foldl1 (</>) entries)

-- ---------------------------------------------------------------------------
-- Generate the module contents

ppHtmlContents
   :: FilePath
   -> String
   -> Maybe String
   -> Maybe String
   -> Maybe String
   -> [(Module,Interface)] -> Maybe Doc
   -> IO ()
ppHtmlContents odir doctitle maybe_package maybe_html_help_format maybe_index_url
  mdls prologue = do
  let tree = mkModuleTree 
         [(mod,iface_package iface,toDescription iface) | (mod,iface) <- mdls]
      html = 
	header 
		(documentCharacterEncoding +++
		 thetitle (toHtml doctitle) +++
		 styleSheet +++
		 (script ! [src jsFile, thetype "text/javascript"] $ noHtml)) +++
        body << vanillaTable << (
   	    simpleHeader doctitle Nothing maybe_index_url </>
	    ppPrologue doctitle prologue </>
	    ppModuleTree doctitle tree </>
	    s15 </>
	    footer
	  )
  writeFile (pathJoin [odir, contentsHtmlFile]) (renderHtml html)
  
  -- Generate contents page for Html Help if requested
  case maybe_html_help_format of
    Nothing        -> return ()
    Just "mshelp"  -> ppHHContents  odir doctitle maybe_package tree
    Just "mshelp2" -> ppHH2Contents odir doctitle maybe_package tree
    Just "devhelp" -> return ()
    Just format    -> fail ("The "++format++" format is not implemented")

ppPrologue :: String -> Maybe Doc -> HtmlTable
ppPrologue title Nothing = Html.emptyTable
ppPrologue title (Just doc) = 
  (tda [theclass "section1"] << toHtml title) </>
  docBox (docToHtml doc)

ppModuleTree :: String -> [ModuleTree] -> HtmlTable
ppModuleTree _ ts = 
  tda [theclass "section1"] << toHtml "Modules" </>
  pad_td Nothing << vanillaTable << htmlTable
  where
    genTable htmlTable id []     = (htmlTable,id)
    genTable htmlTable id (x:xs) = genTable (htmlTable </> u) id' xs      
      where
        (u,id') = mkNode [] x id

    (htmlTable,_) = genTable emptyTable 0 ts

mkNode :: [String] -> ModuleTree -> Int -> (HtmlTable,Int)
mkNode ss (Node s leaf pkg short ts) id = htmlNode
  where
    htmlNode = case ts of
      [] -> ( pad_td (Just 1.25) << htmlModule  <-> shortDescr <-> htmlPkg,id)
      _  -> ((pad_td Nothing<< (collapsebutton id_s +++ htmlModule) <-> shortDescr <-> htmlPkg) </> 
                (pad_td (Just 2) << sub_tree), id')

    shortDescr :: HtmlTable
    shortDescr = case short of
	Nothing -> td empty
	Just doc -> tda [theclass "rdoc"] (docToHtml doc)

    htmlModule 
      | leaf      = ppHsModule mdl
      | otherwise = toHtml s

    htmlPkg = case pkg of
      Nothing -> tda [width "1"] << empty
      Just p  -> td << toHtml p

    mdl = foldr (++) "" (s' : map ('.':) ss')
    (s':ss') = reverse (s:ss)
	 -- reconstruct the module name
    
    id_s = "n:" ++ show id
    
    (sub_tree,id') = genSubTree emptyTable (id+1) ts
    
    genSubTree :: HtmlTable -> Int -> [ModuleTree] -> (Html,Int)
    genSubTree htmlTable id [] = (sub_tree,id)
      where
        sub_tree = collapsed vanillaTable id_s htmlTable
    genSubTree htmlTable id (x:xs) = genSubTree (htmlTable </> u) id' xs      
      where
        (u,id') = mkNode (s:ss) x id

pad_td :: Maybe Float -> Html -> HtmlTable
pad_td Nothing  = tda [width "100%"]
pad_td (Just n) = tda [thestyle ("padding-left:" ++ show n ++ "em"), width "100%"]

-- ---------------------------------------------------------------------------
-- Generate the index

ppHtmlIndex :: FilePath
            -> String 
            -> Maybe String
            -> Maybe String
            -> Maybe String
            -> [(Module,Interface)] 
            -> IO ()
ppHtmlIndex odir doctitle maybe_package maybe_html_help_format maybe_contents_url ifaces = do
  let html = 
	header (documentCharacterEncoding +++
		thetitle (toHtml (doctitle ++ " (Index)")) +++
		styleSheet) +++
        body << vanillaTable << (
	    simpleHeader doctitle maybe_contents_url Nothing </>
	    index_html
	   )

  when split_indices $
    mapM_ (do_sub_index index) initialChars

  writeFile (pathJoin [odir, indexHtmlFile]) (renderHtml html)
  
    -- Generate index and contents page for Html Help if requested
  case maybe_html_help_format of
    Nothing        -> return ()
    Just "mshelp"  -> ppHHIndex  odir maybe_package ifaces
    Just "mshelp2" -> ppHH2Index odir maybe_package ifaces
    Just "devhelp" -> return ()
    Just format    -> fail ("The "++format++" format is not implemented")
 where
  split_indices = length index > 50

  index_html
    | split_indices = 
	tda [theclass "section1"] << 
	      	toHtml ("Index") </>
	indexInitialLetterLinks
   | otherwise =
	td << table ! [cellpadding 0, cellspacing 5] <<
	  aboves (map indexElt index) 
 	
  indexInitialLetterLinks = 
	td << table ! [cellpadding 0, cellspacing 5] <<
	    besides [ td << anchor ! [href (subIndexHtmlFile c)] <<
			 toHtml [c]
		    | c <- initialChars
                    , any ((==c) . toUpper . head . fst) index ]

  do_sub_index this_ix c
    = unless (null index_part) $
        writeFile (pathJoin [odir, subIndexHtmlFile c]) (renderHtml html)
    where 
      html = header (documentCharacterEncoding +++
		thetitle (toHtml (doctitle ++ " (Index)")) +++
		styleSheet) +++
             body << vanillaTable << (
	        simpleHeader doctitle maybe_contents_url Nothing </>
		indexInitialLetterLinks </>
	        tda [theclass "section1"] << 
	      	toHtml ("Index (" ++ c:")") </>
	        td << table ! [cellpadding 0, cellspacing 5] <<
	      	  aboves (map indexElt index_part) 
	       )

      index_part = [(n,stuff) | (n,stuff) <- this_ix, toUpper (head n) == c]

  index :: [(String, Map HsQName [(Module,Bool)])]
  index = sortBy cmp (Map.toAscList full_index)
    where cmp (n1,_) (n2,_) = n1 `compare` n2

  -- for each name (a plain string), we have a number of original HsNames that
  -- it can refer to, and for each of those we have a list of modules
  -- that export that entity.  Each of the modules exports the entity
  -- in a visible or invisible way (hence the Bool).
  full_index :: Map String (Map HsQName [(Module,Bool)])
  full_index = Map.fromListWith (\l r -> Map.unionWith (++) r l)
		(concat (map getIfaceIndex ifaces))

  getIfaceIndex (mdl,iface) = 
    [ (hsNameStr nm, 
	Map.fromList [(orig, [(mdl, not (nm `Map.member` iface_reexported iface))])])
    | (nm, orig) <- Map.toAscList (iface_env iface) ]

  indexElt :: (String, Map HsQName [(Module,Bool)]) -> HtmlTable
  indexElt (str, entities) = 
     case Map.toAscList entities of
	[(nm,entries)] ->  
	    tda [ theclass "indexentry" ] << toHtml str <-> 
			indexLinks (unQual nm) entries
	many_entities ->
	    tda [ theclass "indexentry" ] << toHtml str </> 
		aboves (map doAnnotatedEntity (zip [1..] many_entities))

  unQual (Qual _ nm) = nm
  unQual (UnQual nm) = nm

  doAnnotatedEntity (j,(qnm,entries))
	= tda [ theclass "indexannot" ] << 
		toHtml (show j) <+> parens (ppAnnot nm) <->
		 indexLinks nm entries
	where nm = unQual qnm

  ppAnnot (HsTyClsName n)
       = toHtml "Type/Class"
  ppAnnot (HsVarName n)
       | isUpper c || c == ':'  = toHtml "Data Constructor"
       | otherwise		= toHtml "Function"
      where c = head (hsIdentifierStr n)

  indexLinks nm entries = 
     tda [ theclass "indexlinks" ] << 
	hsep (punctuate comma 
	[ if visible then
	     linkId (Module mdl) (Just nm) << toHtml mdl
	  else
	     toHtml mdl
	| (Module mdl, visible) <- entries ])

  initialChars = [ 'A'..'Z' ] ++ ":!#$%&*+./<=>?@\\^|-~"

-- ---------------------------------------------------------------------------
-- Generate the HTML page for a module

ppHtmlModule
	:: FilePath -> String -> Maybe String -> Maybe String -> Maybe String
	-> (Module,Interface) -> IO ()
ppHtmlModule odir doctitle source_url 
  maybe_contents_url maybe_index_url (Module mdl,iface) = do
  let html = 
	header (documentCharacterEncoding +++
		thetitle (toHtml mdl) +++
		styleSheet +++
		(script ! [src jsFile, thetype "text/javascript"] $ noHtml)) +++
        body << vanillaTable << (
	    pageHeader mdl iface doctitle source_url 
		maybe_contents_url maybe_index_url </> s15 </>
	    ifaceToHtml mdl iface </> s15 </>
	    footer
         )
  writeFile (pathJoin [odir, moduleHtmlFile mdl]) (renderHtml html)

ifaceToHtml :: String -> Interface -> HtmlTable
ifaceToHtml _ iface 
  = abovesSep s15 (contents: description: synopsis: maybe_doc_hdr: bdy)
  where 
	exports = numberSectionHeadings (iface_exports iface)

	has_doc (ExportDecl _ d _) = isJust (declDoc d)
	has_doc (ExportNoDecl _ _ _) = False
	has_doc (ExportModule _) = False
	has_doc _ = True

	no_doc_at_all = not (any has_doc exports)

	contents = td << vanillaTable << ppModuleContents exports

	description
         | Just doc <- iface_doc iface
         = (tda [theclass "section1"] << toHtml "Description") </>
	   docBox (docToHtml doc)
	 | otherwise
	 = Html.emptyTable

	-- omit the synopsis if there are no documentation annotations at all
	synopsis
	  | no_doc_at_all = Html.emptyTable
	  | otherwise
	  = (tda [theclass "section1"] << toHtml "Synopsis") </>
	    s15 </>
            (tda [theclass "body"] << vanillaTable <<
  	        abovesSep s8 (map (processExport True)
			(filter forSummary exports))
	    )

	-- if the documentation doesn't begin with a section header, then
	-- add one ("Documentation").
	maybe_doc_hdr
	    = case exports of		   
		   [] -> Html.emptyTable
		   ExportGroup _ _ _ : _ -> Html.emptyTable
		   _ -> tda [ theclass "section1" ] << toHtml "Documentation"

	bdy  = map (processExport False) exports

ppModuleContents :: [ExportItem] -> HtmlTable
ppModuleContents exports
  | length sections == 0 = Html.emptyTable
  | otherwise            = tda [theclass "section4"] << bold << toHtml "Contents"
  		           </> td << dlist << concatHtml sections
 where
  (sections, _leftovers{-should be []-}) = process 0 exports

  process :: Int -> [ExportItem] -> ([Html],[ExportItem])
  process _ [] = ([], [])
  process n items@(ExportGroup lev id0 doc : rest) 
    | lev <= n  = ( [], items )
    | otherwise = ( html:secs, rest2 )
    where
	html = (dterm << linkedAnchor id0 << docToHtml doc)
		 +++ mk_subsections ssecs
	(ssecs, rest1) = process lev rest
	(secs,  rest2) = process n   rest1
  process n (_ : rest) = process n rest

  mk_subsections [] = noHtml
  mk_subsections ss = ddef << dlist << concatHtml ss

-- we need to assign a unique id to each section heading so we can hyperlink
-- them from the contents:
numberSectionHeadings :: [ExportItem] -> [ExportItem]
numberSectionHeadings exports = go 1 exports
  where go :: Int -> [ExportItem] -> [ExportItem]
        go _ [] = []
	go n (ExportGroup lev _ doc : es) 
	  = ExportGroup lev (show n) doc : go (n+1) es
	go n (other:es)
	  = other : go n es

processExport :: Bool -> ExportItem -> HtmlTable
processExport _ (ExportGroup lev id0 doc)
  = ppDocGroup lev (namedAnchor id0 << docToHtml doc)
processExport summary (ExportDecl x decl insts)
  = doDecl summary x decl insts
processExport summmary (ExportNoDecl _ y [])
  = declBox (ppHsQName y)
processExport summmary (ExportNoDecl _ y subs)
  = declBox (ppHsQName y <+> parenList (map ppHsQName subs))
processExport _ (ExportDoc doc)
  = docBox (docToHtml doc)
processExport _ (ExportModule (Module mdl))
  = declBox (toHtml "module" <+> ppHsModule mdl)

forSummary :: ExportItem -> Bool
forSummary (ExportGroup _ _ _) = False
forSummary (ExportDoc _)       = False
forSummary _                   = True

ppDocGroup :: Int -> Html -> HtmlTable
ppDocGroup lev doc
  | lev == 1  = tda [ theclass "section1" ] << doc
  | lev == 2  = tda [ theclass "section2" ] << doc
  | lev == 3  = tda [ theclass "section3" ] << doc
  | otherwise = tda [ theclass "section4" ] << doc

-- -----------------------------------------------------------------------------
-- Converting declarations to HTML

declWithDoc :: Bool -> Maybe Doc -> Html -> HtmlTable
declWithDoc True  _          html_decl = declBox html_decl
declWithDoc False Nothing    html_decl = declBox html_decl
declWithDoc False (Just doc) html_decl = 
		declBox html_decl </> docBox (docToHtml doc)

doDecl :: Bool -> HsQName -> HsDecl -> [InstHead] -> HtmlTable
doDecl summary x d instances = do_decl d
  where
     do_decl (HsTypeSig _ [nm] ty doc) 
	= ppFunSig summary nm ty doc

     do_decl (HsForeignImport _ _ _ _ n ty doc)
	= ppFunSig summary n ty doc

     do_decl (HsTypeDecl _ nm args ty doc)
	= declWithDoc summary doc (
	      hsep ([keyword "type", ppHsBinder summary nm]
		 ++ map ppHsName args) <+> equals <+> ppHsType ty)

     do_decl (HsNewTypeDecl loc ctx nm args con drv doc)
	= ppHsDataDecl summary instances True{-is newtype-} x
		(HsDataDecl loc ctx nm args [con] drv doc)
	  -- print it as a single-constructor datatype

     do_decl d0@(HsDataDecl{})
	= ppHsDataDecl summary instances False{-not newtype-} x d0

     do_decl d0@(HsClassDecl{})
	= ppHsClassDecl summary instances x d0

     do_decl (HsDocGroup _ lev str)
	= if summary then Html.emptyTable 
		     else ppDocGroup lev (docToHtml str)

     do_decl _ = error ("do_decl: " ++ show d)


ppTypeSig :: Bool -> HsName -> HsType -> Html
ppTypeSig summary nm ty = ppHsBinder summary nm <+> dcolon <+> ppHsType ty

-- -----------------------------------------------------------------------------
-- Data & newtype declarations

ppShortDataDecl :: Bool -> Bool -> HsDecl -> Html
ppShortDataDecl summary is_newty 
	(HsDataDecl _ _ nm args [con] _ _doc) =
   ppHsDataHeader summary is_newty nm args      
     <+> equals <+> ppShortConstr summary con
ppShortDataDecl summary is_newty
	(HsDataDecl _ _ nm args [] _ _doc) = 
   ppHsDataHeader summary is_newty nm args
ppShortDataDecl summary is_newty
	(HsDataDecl _ _ nm args cons _ _doc) = 
   vanillaTable << (
	declBox (ppHsDataHeader summary is_newty nm args) </>
	tda [theclass "body"] << vanillaTable << (
	  aboves (zipWith do_constr ('=':repeat '|') cons)
        )
   )
  where do_constr c con = declBox (toHtml [c] <+> ppShortConstr summary con)
ppShortDataDecl _ _ d =
    error $ "HaddockHtml.ppShortDataDecl: unexpected decl " ++ show d

-- The rest of the cases:
ppHsDataDecl :: Ord key => Bool	-> [InstHead] -> Bool -> key -> HsDecl -> HtmlTable
ppHsDataDecl summary instances is_newty 
     x decl@(HsDataDecl _ _ nm args cons _ doc)
  | summary = declWithDoc summary doc (ppShortDataDecl summary is_newty decl)

  | otherwise
        = dataheader </> 
	    tda [theclass "body"] << vanillaTable << (
		datadoc </> 
		constr_bit </>
		instances_bit
            )
  where
	dataheader = declBox (ppHsDataHeader False is_newty nm args)

	constr_table
	 	| any isRecDecl cons  = spacedTable5
	  	| otherwise           = spacedTable1

	datadoc | isJust doc = ndocBox (docToHtml (fromJust doc))
	  	| otherwise  = Html.emptyTable

	constr_bit 
		| null cons = Html.emptyTable
		| otherwise = 
			constr_hdr </>
			(tda [theclass "body"] << constr_table << 
			 aboves (map ppSideBySideConstr cons)
			)

	inst_id = collapseId nm

	instances_bit
	   | null instances = Html.emptyTable
	   | otherwise
	   =  inst_hdr inst_id </>
		 tda [theclass "body"] << 
		    collapsed thediv inst_id (
			spacedTable1 << (
			   aboves (map (declBox.ppInstHead) instances)
		        )
 		   )

ppHsDataDecl _ _ _ _ d =
    error $ "HaddockHtml.ppHsDataDecl: unexpected decl " ++ show d

isRecDecl :: HsConDecl -> Bool
isRecDecl (HsRecDecl{}) = True
isRecDecl _             = False

ppShortConstr :: Bool -> HsConDecl -> Html
ppShortConstr summary (HsConDecl _ nm tvs ctxt typeList _maybe_doc) = 
   ppHsConstrHdr tvs ctxt +++
	hsep (ppHsBinder summary nm : map ppHsBangType typeList)
ppShortConstr summary (HsRecDecl _ nm tvs ctxt fields _) =
   ppHsConstrHdr tvs ctxt +++
   ppHsBinder summary nm <+>
   braces (vanillaTable << aboves (map (ppShortField summary) fields))

ppHsConstrHdr :: [HsName] -> HsContext -> Html
ppHsConstrHdr tvs ctxt
 = (if null tvs then noHtml else keyword "forall" <+> 
				 hsep (map ppHsName tvs) <+> 
				 toHtml ". ")
   +++
   (if null ctxt then noHtml else ppHsContext ctxt <+> toHtml "=> ")

ppSideBySideConstr :: HsConDecl -> HtmlTable
ppSideBySideConstr (HsConDecl _ nm tvs ctxt typeList doc) =
  argBox (hsep ((ppHsConstrHdr tvs ctxt +++ 
		ppHsBinder False nm) : map ppHsBangType typeList)) <->
  maybeRDocBox doc
ppSideBySideConstr (HsRecDecl _ nm tvs ctxt fields doc) =
  argBox (ppHsConstrHdr tvs ctxt +++ ppHsBinder False nm) <->
  maybeRDocBox doc </>
  (tda [theclass "body"] << spacedTable1 <<
     aboves (map ppSideBySideField fields))

ppSideBySideField :: HsFieldDecl -> HtmlTable
ppSideBySideField (HsFieldDecl ns ty doc) =
  argBox (hsep (punctuate comma (map (ppHsBinder False) ns))
	   <+> dcolon <+> ppHsBangType ty) <->
  maybeRDocBox doc

{-
ppHsFullConstr :: HsConDecl -> Html
ppHsFullConstr (HsConDecl _ nm tvs ctxt typeList doc) = 
     declWithDoc False doc (
	hsep ((ppHsConstrHdr tvs ctxt +++ 
		ppHsBinder False nm) : map ppHsBangType typeList)
      )
ppHsFullConstr (HsRecDecl _ nm tvs ctxt fields doc) =
   td << vanillaTable << (
     case doc of
       Nothing -> aboves [hdr, fields_html]
       Just _  -> aboves [hdr, constr_doc, fields_html]
   )

  where hdr = declBox (ppHsConstrHdr tvs ctxt +++ ppHsBinder False nm)

	constr_doc	
	  | isJust doc = docBox (docToHtml (fromJust doc))
	  | otherwise  = Html.emptyTable

	fields_html = 
	   td << 
	      table ! [width "100%", cellpadding 0, cellspacing 8] << (
		   aboves (map ppFullField (concat (map expandField fields)))
		)
-}

ppShortField :: Bool -> HsFieldDecl -> HtmlTable
ppShortField summary (HsFieldDecl ns ty _doc) 
  = tda [theclass "recfield"] << (
	  hsep (punctuate comma (map (ppHsBinder summary) ns))
	    <+> dcolon <+> ppHsBangType ty
   )

{-
ppFullField :: HsFieldDecl -> Html
ppFullField (HsFieldDecl [n] ty doc) 
  = declWithDoc False doc (
	ppHsBinder False n <+> dcolon <+> ppHsBangType ty
    )
ppFullField _ = error "ppFullField"

expandField :: HsFieldDecl -> [HsFieldDecl]
expandField (HsFieldDecl ns ty doc) = [ HsFieldDecl [n] ty doc | n <- ns ]
-}

ppHsDataHeader :: Bool -> Bool -> HsName -> [HsName] -> Html
ppHsDataHeader summary is_newty nm args = 
  (if is_newty then keyword "newtype" else keyword "data") <+> 
	ppHsBinder summary nm <+> hsep (map ppHsName args)

ppHsBangType :: HsBangType -> Html
ppHsBangType (HsBangedTy ty) = char '!' +++ ppHsAType ty
ppHsBangType (HsUnBangedTy ty) = ppHsAType ty

-- -----------------------------------------------------------------------------
-- Class declarations

ppClassHdr :: Bool -> HsContext -> HsName -> [HsName] -> [HsFunDep] -> Html
ppClassHdr summ [] n tvs fds = 
  keyword "class"
	<+> ppHsBinder summ n <+> hsep (map ppHsName tvs)
	<+> ppFds fds
ppClassHdr summ ctxt n tvs fds = 
  keyword "class" <+> ppHsContext ctxt <+> darrow
	<+> ppHsBinder summ n <+> hsep (map ppHsName tvs)
	<+> ppFds fds

ppFds :: [HsFunDep] -> Html
ppFds fds =
  if null fds then noHtml else 
	char '|' <+> hsep (punctuate comma (map fundep fds))
  where
	fundep (vars1,vars2) = hsep (map ppHsName vars1) <+> toHtml "->" <+>
			       hsep (map ppHsName vars2)

ppShortClassDecl :: Bool -> HsDecl -> HtmlTable
ppShortClassDecl summary (HsClassDecl _ ctxt nm tvs fds decls _) = 
  if null decls
    then declBox hdr
    else declBox (hdr <+> keyword "where")
	    </> 
           (tda [theclass "body"] << 
	     vanillaTable << 
	       aboves [ ppFunSig summary n ty doc 
		      | HsTypeSig _ [n] ty doc <- decls
		      ]
          )
         
   where
	hdr = ppClassHdr summary ctxt nm tvs fds
ppShortClassDecl _ d =
    error $ "HaddockHtml.ppShortClassDecl: unexpected decl: " ++ show d

ppHsClassDecl :: Ord key => Bool -> [InstHead] -> key -> HsDecl -> HtmlTable
ppHsClassDecl summary instances orig_c
	decl@(HsClassDecl _ ctxt nm tvs fds decls doc)
  | summary = ppShortClassDecl summary decl

  | otherwise
        = classheader </>
		tda [theclass "body"] << vanillaTable << (
		   classdoc </> methods_bit </> instances_bit
		)

   where 
	classheader
	   | null decls = declBox hdr
	   | otherwise  = declBox (hdr <+> keyword "where")

	hdr = ppClassHdr summary ctxt nm tvs fds

	classdoc
	   | Just d <- doc = ndocBox (docToHtml d)
	   | otherwise     = Html.emptyTable

	methods_bit
	   | null decls = Html.emptyTable
	   | otherwise  = 
		s8 </> meth_hdr </>
		tda [theclass "body"] << vanillaTable << (
	       		abovesSep s8 [ ppFunSig summary n ty doc0
			             | HsTypeSig _ [n] ty doc0 <- decls
			             ]
			)

	inst_id = collapseId nm
 	instances_bit
	   | null instances = Html.emptyTable
	   | otherwise 
	   =  s8 </> inst_hdr inst_id </>
		 tda [theclass "body"] << 
		   collapsed thediv inst_id (
		      spacedTable1 << (
			aboves (map (declBox.ppInstHead) instances)
		  ))

ppHsClassDecl _ _ _ d =
    error $ "HaddockHtml.ppHsClassDecl: unexpected decl: " ++ show d


ppInstHead	       :: InstHead -> Html
ppInstHead ([],asst)   =  ppHsAsst asst
ppInstHead (ctxt,asst) =  ppHsContext ctxt <+> darrow <+> ppHsAsst asst

-- ----------------------------------------------------------------------------
-- Type signatures

ppFunSig :: Bool -> HsName -> HsType -> Maybe Doc -> HtmlTable
ppFunSig summary nm ty0 doc
  | summary || no_arg_docs ty0 = 
      declWithDoc summary doc (ppTypeSig summary nm ty0)

  | otherwise   = 
	declBox (ppHsBinder False nm) </>
	(tda [theclass "body"] << vanillaTable <<  (
	   do_args dcolon ty0 </>
	   (if (isJust doc) 
		then ndocBox (docToHtml (fromJust doc))
		else Html.emptyTable)
	))
  where
	no_arg_docs (HsForAllType _ _ ty) = no_arg_docs ty
	no_arg_docs (HsTyFun (HsTyDoc _ _) _) = False
	no_arg_docs (HsTyFun _ r) = no_arg_docs r
	no_arg_docs (HsTyDoc _ _) = False
 	no_arg_docs _ = True

	do_args :: Html -> HsType -> HtmlTable
	do_args leader (HsForAllType (Just tvs) ctxt ty)
	  = (argBox (
		leader <+> 
		hsep (keyword "forall" : map ppHsName tvs ++ [toHtml "."]) <+>
		ppHsIPContext ctxt)
	      <-> rdocBox noHtml) </> 
	    do_args darrow ty
	do_args leader (HsForAllType Nothing ctxt ty)
	  = (argBox (leader <+> ppHsIPContext ctxt)
		<-> rdocBox noHtml) </> 
	    do_args darrow ty
	do_args leader (HsTyFun (HsTyDoc ty doc0) r)
	  = (argBox (leader <+> ppHsBType ty) <-> rdocBox (docToHtml doc0))
            </> do_args arrow r
	do_args leader (HsTyFun ty r)
	  = (argBox (leader <+> ppHsBType ty) <-> rdocBox noHtml) </>
	    do_args arrow r
	do_args leader (HsTyDoc ty doc0)
	  = (argBox (leader <+> ppHsBType ty) <-> rdocBox (docToHtml doc0))
	do_args leader ty
	  = argBox (leader <+> ppHsBType ty) <-> rdocBox (noHtml)

-- ----------------------------------------------------------------------------
-- Types and contexts

ppHsAsst	  :: HsAsst -> Html
ppHsAsst (c,args) =  ppHsQName c <+> hsep (map ppHsAType args)

ppHsContext	  :: HsContext -> Html
ppHsContext []      =  empty
ppHsContext [ctxt]  =  ppHsAsst ctxt
ppHsContext context =  parenList (map ppHsAsst context)

ppHsCtxt :: HsCtxt -> Html
ppHsCtxt (HsAssump asst) = ppHsAsst asst
ppHsCtxt (HsIP n t)      = toHtml "?" +++ ppHsName n <+> dcolon <+> ppHsType t

ppHsIPContext	      :: HsIPContext -> Html
ppHsIPContext []      =  empty
ppHsIPContext [ctxt]  =  ppHsCtxt ctxt
ppHsIPContext context =  parenList (map ppHsCtxt context)

ppHsForAll :: Maybe [HsName] -> HsIPContext -> Html
ppHsForAll Nothing context = 
  hsep [ ppHsIPContext context, darrow ]
ppHsForAll (Just tvs) [] = 
  hsep (keyword "forall" : map ppHsName tvs ++ [toHtml "."])
ppHsForAll (Just tvs) context =
  hsep (keyword "forall" : map ppHsName tvs ++ 
	  [toHtml ".", ppHsIPContext context, darrow])

ppHsType :: HsType -> Html
ppHsType (HsForAllType maybe_tvs context htype) =
  ppHsForAll maybe_tvs context <+> ppHsType htype
ppHsType (HsTyFun a b) = hsep [ppHsBType a, toHtml "->", ppHsType b]
ppHsType (HsTyIP n t)  = toHtml "?" +++ ppHsName n <+> dcolon <+> ppHsType t
ppHsType t = ppHsBType t

ppHsBType :: HsType -> Html
ppHsBType (HsTyDoc ty _) = ppHsBType ty
ppHsBType (HsTyApp (HsTyCon (Qual _ (HsTyClsName (HsSpecial "[]")))) b )
  = brackets $ ppHsType b
ppHsBType (HsTyApp a b) = ppHsBType a <+> ppHsAType b
ppHsBType t = ppHsAType t

ppHsAType :: HsType -> Html
ppHsAType (HsTyTuple True l)  = parenList . map ppHsType $ l
ppHsAType (HsTyTuple False l) = ubxParenList . map ppHsType $ l
ppHsAType (HsTyVar nm) = ppHsName nm
ppHsAType (HsTyCon nm)
  | nm == fun_tycon_qname = parens $ ppHsQName nm
  | otherwise               = ppHsQName nm
ppHsAType (HsTyApp (HsTyCon (Qual _ (HsTyClsName (HsSpecial "[]")))) b )
  = brackets $ ppHsType b
ppHsAType t = parens $ ppHsType t

-- ----------------------------------------------------------------------------
-- Names

linkTarget :: HsName -> Html
linkTarget nm = namedAnchor (hsAnchorNameStr nm) << toHtml ""

ppHsQName :: HsQName -> Html
ppHsQName (UnQual str) = ppHsName str
ppHsQName n@(Qual mdl str)
  | n == unit_con_name	= ppHsName str
  | isSpecial str	= ppHsName str
  | otherwise		= linkId mdl (Just str) << ppHsName str

isSpecial :: HsName -> Bool
isSpecial (HsTyClsName id0) | HsSpecial _ <- id0 = True
isSpecial (HsVarName id0)   | HsSpecial _ <- id0 = True
isSpecial _                                      = False

ppHsName :: HsName -> Html
ppHsName nm = toHtml (hsNameStr nm)

ppHsBinder :: Bool -> HsName -> Html
-- The Bool indicates whether we are generating the summary, in which case
-- the binder will be a link to the full definition.
ppHsBinder True nm = linkedAnchor (hsAnchorNameStr nm) << ppHsBinder' nm
ppHsBinder False nm = linkTarget nm +++ bold << ppHsBinder' nm

ppHsBinder' :: HsName -> Html
ppHsBinder' (HsTyClsName id0) = ppHsBindIdent id0
ppHsBinder' (HsVarName id0)   = ppHsBindIdent id0

ppHsBindIdent :: HsIdentifier -> Html
ppHsBindIdent (HsIdent str)   =  toHtml str
ppHsBindIdent (HsSymbol str)  =  parens (toHtml str)
ppHsBindIdent (HsSpecial str) =  toHtml str

linkId :: Module -> Maybe HsName -> Html -> Html
linkId (Module mdl) mbName = anchor ! [href hr]
  where hr = case mbName of
                  Nothing   -> moduleHtmlFile mdl
                  Just name -> nameHtmlRef mdl name

ppHsModule :: String -> Html
ppHsModule mdl = anchor ! [href ((moduleHtmlFile modname) ++ ref)] << toHtml mdl
  where 
        (modname,ref) = break (== '#') mdl

-- -----------------------------------------------------------------------------
-- * Doc Markup

htmlMarkup :: DocMarkup [HsQName] Html
htmlMarkup = Markup {
  markupParagraph     = paragraph,
  markupEmpty	      = toHtml "",
  markupString        = toHtml,
  markupAppend        = (+++),
  markupIdentifier    = tt . ppHsQName . head,
  markupModule        = ppHsModule,
  markupEmphasis      = emphasize . toHtml,
  markupMonospaced    = tt . toHtml,
  markupUnorderedList = ulist . concatHtml . map (li <<),
  markupOrderedList   = olist . concatHtml . map (li <<),
  markupDefList       = dlist . concatHtml . map markupDef,
  markupCodeBlock     = pre,
  markupURL	      = \url -> anchor ! [href url] << toHtml url,
  markupAName	      = \aname -> namedAnchor aname << toHtml ""
  }

markupDef (a,b) = dterm << a +++ ddef << b

-- If the doc is a single paragraph, don't surround it with <P> (this causes
-- ugly extra whitespace with some browsers).
docToHtml :: Doc -> Html
docToHtml doc = markup htmlMarkup (unParagraph (markup htmlCleanup doc))

-- If there is a single paragraph, then surrounding it with <P>..</P>
-- can add too much whitespace in some browsers (eg. IE).  However if
-- we have multiple paragraphs, then we want the extra whitespace to
-- separate them.  So we catch the single paragraph case and transform it
-- here.
unParagraph (DocParagraph d) = d
--NO: This eliminates line breaks in the code block:  (SDM, 6/5/2003)
--unParagraph (DocCodeBlock d) = (DocMonospaced d)
unParagraph doc              = doc

htmlCleanup :: DocMarkup [HsQName] Doc
htmlCleanup = idMarkup { 
  markupUnorderedList = DocUnorderedList . map unParagraph,
  markupOrderedList   = DocOrderedList   . map unParagraph
  } 

-- -----------------------------------------------------------------------------
-- * Misc

hsep :: [Html] -> Html
hsep [] = noHtml
hsep htmls = foldr1 (\a b -> a+++" "+++b) htmls

infixr 8 <+>
(<+>) :: Html -> Html -> Html
a <+> b = Html (getHtmlElements (toHtml a) ++ HtmlString " ": getHtmlElements (toHtml b))

keyword :: String -> Html
keyword s = thespan ! [theclass "keyword"] << toHtml s

equals, comma :: Html
equals = char '='
comma  = char ','

char :: Char -> Html
char c = toHtml [c]

empty :: Html
empty  = noHtml

parens, brackets, braces :: Html -> Html
parens h        = char '(' +++ h +++ char ')'
brackets h      = char '[' +++ h +++ char ']'
braces h        = char '{' +++ h +++ char '}'

punctuate :: Html -> [Html] -> [Html]
punctuate _ []     = []
punctuate h (d0:ds) = go d0 ds
                   where
                     go d [] = [d]
                     go d (e:es) = (d +++ h) : go e es

abovesSep :: HtmlTable -> [HtmlTable] -> HtmlTable
abovesSep _ []      = Html.emptyTable
abovesSep h (d0:ds) = go d0 ds
                   where
                     go d [] = d
                     go d (e:es) = d </> h </> go e es

parenList :: [Html] -> Html
parenList = parens . hsep . punctuate comma

ubxParenList :: [Html] -> Html
ubxParenList = ubxparens . hsep . punctuate comma

ubxparens :: Html -> Html
ubxparens h = toHtml "(#" +++ h +++ toHtml "#)"

{-
text :: Html
text   = strAttr "TEXT"
-}

-- a box for displaying code
declBox :: Html -> HtmlTable
declBox html = tda [theclass "decl"] << html

-- a box for displaying an 'argument' (some code which has text to the
-- right of it).  Wrapping is not allowed in these boxes, whereas it is
-- in a declBox.
argBox :: Html -> HtmlTable
argBox html = tda [theclass "arg"] << html

-- a box for displaying documentation, 
-- indented and with a little padding at the top
docBox :: Html -> HtmlTable
docBox html = tda [theclass "doc"] << html

-- a box for displaying documentation, not indented.
ndocBox :: Html -> HtmlTable
ndocBox html = tda [theclass "ndoc"] << html

-- a box for displaying documentation, padded on the left a little
rdocBox :: Html -> HtmlTable
rdocBox html = tda [theclass "rdoc"] << html

maybeRDocBox :: Maybe Doc -> HtmlTable
maybeRDocBox Nothing = rdocBox (noHtml)
maybeRDocBox (Just doc) = rdocBox (docToHtml doc)

-- a box for the buttons at the top of the page
topButBox :: Html -> HtmlTable
topButBox html = tda [theclass "topbut"] << html

-- a vanilla table has width 100%, no border, no padding, no spacing
-- a narrow table is the same but without width 100%.
vanillaTable, narrowTable :: Html -> Html
vanillaTable = table ! [theclass "vanilla", cellspacing 0, cellpadding 0]
narrowTable  = table ! [theclass "narrow",  cellspacing 0, cellpadding 0]

spacedTable1, spacedTable5 :: Html -> Html
spacedTable1 = table ! [theclass "vanilla",  cellspacing 1, cellpadding 0]
spacedTable5 = table ! [theclass "vanilla",  cellspacing 5, cellpadding 0]

constr_hdr, meth_hdr :: HtmlTable
constr_hdr  = tda [ theclass "section4" ] << toHtml "Constructors"
meth_hdr    = tda [ theclass "section4" ] << toHtml "Methods"

inst_hdr :: String -> HtmlTable
inst_hdr id = 
  tda [ theclass "section4" ] << (collapsebutton id +++ toHtml " Instances")

dcolon, arrow, darrow :: Html
dcolon = toHtml "::"
arrow  = toHtml "->"
darrow = toHtml "=>"

s8, s15 :: HtmlTable
s8  = tda [ theclass "s8" ]  << noHtml
s15 = tda [ theclass "s15" ] << noHtml

namedAnchor :: String -> Html -> Html
namedAnchor n = anchor ! [name (escapeStr n)]

--
-- A section of HTML which is collapsible via a +/- button.
--

-- TODO: Currently the initial state is non-collapsed. Change the 'minusFile'
-- below to a 'plusFile' and the 'display:block;' to a 'display:none;' when we
-- use cookies from JavaScript to have a more persistent state.

collapsebutton :: String -> Html
collapsebutton id = 
  image ! [ src minusFile, theclass "coll", onclick ("toggle(this,'" ++ id ++ "')"), alt "show/hide" ]

collapsed :: (HTML a) => (Html -> Html) -> String -> a -> Html
collapsed fn id html =
  fn ! [identifier id, thestyle "display:block;"] << html

-- A quote is a valid part of a Haskell identifier, but it would interfere with
-- the ECMA script string delimiter used in collapsebutton above.
collapseId :: HsName -> String
collapseId nm = "i:" ++ escapeStr (hsNameStr nm)

linkedAnchor :: String -> Html -> Html
linkedAnchor frag = anchor ! [href hr]
   where hr | null frag = ""
            | otherwise = '#': escapeStr frag

documentCharacterEncoding :: Html
documentCharacterEncoding =
   meta ! [httpequiv "Content-Type", content "text/html; charset=UTF-8"]

styleSheet :: Html
styleSheet =
   thelink ! [href cssFile, rel "stylesheet", thetype "text/css"]
