xquery version "3.1";

(:~
 : The generalized functions for generating the content of ediarum.web.
 :)
module namespace edwebapi="http://www.bbaw.de/telota/software/ediarum/web/api";

import module namespace edwebcontroller="http://www.bbaw.de/telota/software/ediarum/web/controller";

declare namespace appconf="http://www.bbaw.de/telota/software/ediarum/web/appconf";
declare namespace repo="http://exist-db.org/xquery/repo";
declare namespace expath="http://expath.org/ns/pkg";
declare namespace tei="http://www.tei-c.org/ns/1.0";
declare namespace functx = "http://www.functx.com";
declare namespace output="http://www.w3.org/2010/xslt-xquery-serialization";
declare namespace test="http://exist-db.org/xquery/xqsuite";
declare namespace http="http://expath.org/ns/http-client";

declare variable $edwebapi:controller := "/ediarum.web";
declare variable $edwebapi:cache-collection := "/db/apps/ediarum.web/cache";
declare variable $edwebapi:projects-collection := "/db/projects";
(: See also $edweb:param-separator. :)
declare variable $edwebapi:param-separator := ";";

declare function functx:get-matches-and-non-matches($string as xs:string?, $regex as xs:string) as element()* {let $iomf := functx:index-of-match-first($string, $regex)return if (empty($iomf))then <non-match>{$string}</non-match>else if ($iomf > 1)then (<non-match>{substring($string,1,$iomf - 1)}</non-match>,functx:get-matches-and-non-matches(substring($string,$iomf),$regex))else let $length :=string-length($string)-string-length(functx:replace-first($string, $regex,''))return (<match>{substring($string,1,$length)}</match>,if (string-length($string) > $length)then functx:get-matches-and-non-matches(substring($string,$length + 1),$regex)else ())};
declare function functx:index-of-match-first($arg as xs:string?, $pattern as xs:string) as xs:integer? {if (matches($arg,$pattern))then string-length(tokenize($arg, $pattern)[1]) + 1 else ()};
declare function functx:pad-integer-to-length($integerToPad as xs:anyAtomicType?, $length as xs:integer) as xs:string {if ($length < string-length(string($integerToPad)))then error(xs:QName('functx:Integer_Longer_Than_Length'))else concat(functx:repeat-string('0',$length - string-length(string($integerToPad))),string($integerToPad))};
declare function functx:replace-first($arg as xs:string?, $pattern as xs:string, $replacement as xs:string) as xs:string {replace($arg, concat('(^.*?)', $pattern),concat('$1',$replacement))};
declare function functx:repeat-string($stringToRepeat as xs:string?, $count as xs:integer) as xs:string {string-join((for $i in 1 to $count return $stringToRepeat), '')};

(:~
 : 
 :)
declare function edwebapi:filter-list(
    $list as map(*)*, 
    $filters as map(*), 
    $params as map(*)
) as map(*)* 
{
    if (count(map:keys($filters)) > 0) then
        let $filter := $filters?*[1]
        let $filter-id := $filter?id
        let $filter-values := tokenize($params?($filter-id), $edwebapi:param-separator)
        let $filter-expression :=
            if (empty($filter-values)) 
            then function($list as map(*)*) { $list}
            else
                switch($filter?type)
                case "id" 
                return function($list as map(*)*) { $list[?filter?($filter-id) = $filter-values] }
                case "single" 
                return function($list as map(*)*) { $list[?filter?($filter-id) = $filter-values] }
                case "union" 
                return function($list as map(*)*) { $list[?filter?($filter-id) = $filter-values] }
                case "intersect" 
                return
                    function($list as map(*)*) {
                        for $item in $list 
                        let $item-filter-values := $item?filter?($filter-id)
                        let $filters-are-true := 
                            for $fv in $filter-values 
                            return ($fv = $item-filter-values) 
                        return
                            if (not( false() = ($filters-are-true) )) 
                            then $item
                            else ()
                    }
                case "greater-than" 
                return function($list as map(*)*) { $list[?filter?($filter-id) >= $filter-values] }
                case "lower-than" 
                return function($list as map(*)*) { $list[?filter?($filter-id) <= $filter-values] }
                default 
                return function($list as map(*)*) { () }
        let $filtered-list := $filter-expression($list)
        let $other-filter := map:remove($filters, $filter-id)
        return
            if (count(map:keys($other-filter)) > 0) 
            then edwebapi:filter-list($filtered-list, $other-filter, $params)
            else $filtered-list
    else $list
};

(:~
 :
 :)
declare function edwebapi:get-all(
    $app-target as xs:string,
    $cache as xs:string?
) 
{
    let $object-types := edwebapi:get-config($app-target)//appconf:object/@xml:id
    let $found-objects :=
        for $object-type in $object-types
        let $map :=
            edwebapi:load-map-from-cache(
                "edwebapi:get-object-list", 
                [$app-target, $object-type], 
                if ($cache = "yes")
                then ()
                else collection(edwebapi:data-collection($app-target))/*, 
                $cache = "no"
            )
        return $map?list
    return
        map:merge((map:entry("date-time", current-dateTime()), $found-objects))
};

(:~
 : Retrieves the appconf.xml from the project app.
 :
 : @param $app-target the collection name where the app is installed, e.g. project.WEB
 : @return the appconf.xml as node
 :)
declare function edwebapi:get-config(
    $app-target as xs:string
) as node()*
{
    doc($app-target||"/appconf.xml")
};

(:~
 :
 :)
declare function edwebapi:list-parts(
    $xml, 
    $parts, 
    $part-name, 
    $object-type, 
    $object-id
) 
{
    let $part := $parts?($part-name)
    let $root := $part?root
    let $id-path := $part?id
    let $xpath := ".//" || $root || "/" || $id-path
    let $depends := $part?depends
    (: Wenn es depend gibt, .. :)
    return
        if ($depends != "") 
        then
            (: .. gib den 'path' mit, suche die dortigen IDs und liefere subxml, sowie den 
               ersetzten 'path' zurück. :)
            let $depend-maps := 
                local:list-part-ids(
                    $xml, 
                    $parts?($depends), 
                    $part?path, 
                    $object-type, 
                    $object-id
                )
            (: Dann suche nach Teilen im 'subxml' .. :)
            for $d-map in $depend-maps
            let $ids := util:eval-inline($d-map?xml, $xpath)
            (: .. und ersetze im 'path' die aktuelle IDs. :)
            for $id in $ids
            return replace($d-map?path, "<" || $part?xmlid || ">", $id)
        else
            (: Sonst suche im XML und ersetze im 'path' die aktuelle ID. :)
            let $ids := util:eval-inline($xml, $xpath)
            for $id in $ids
            return replace($part?path, "<" || $part?xmlid || ">", $id)
};

(:~
 :
 :)
declare function local:list-part-ids(
    $xml, 
    $part, 
    $path, 
    $object-type, 
    $object-id
) 
{
    let $root := $part?root
    let $id-path := $part?id
    let $xpath := ".//" || $root || "[" || $id-path || "]"
    let $nodes := util:eval-inline($xml, $xpath)
    for $node in $nodes
    let $id := util:eval-inline($node, $id-path)
    let $sub-path := replace($path, "<" || $part?xmlid || ">", $id)
    let $this-path := replace($part?path, "<" || $part?xmlid || ">", $id)
    let $sub-xml := edwebcontroller:api-get("/api/"||$object-type||"/"||$object-id||"/"||$this-path)
    return
        map:merge((
            map:entry("id", $id),
            map:entry("path", $sub-path),
            map:entry("xml", $sub-xml)
        ))
};

(:~
 : Retrieves and stores the result of a function in cache. Only executes the function if no cache
 : exists or if the cache is out of date because data updates.
 : 
 : @param $function-name the name of the function to apply
 : @param $params an array of the function params
 : $node-set the node set the cache date is compared to
 : @reload if true the cache is always rebuild
 : @return the result of the function as a map.
 :)
declare function edwebapi:load-map-from-cache(
    $function-name as xs:string, 
    $params as array(*), 
    $node-set as node()*, 
    $reload as xs:boolean?
) as map(*) 
{
    let $arity := array:size($params)
    let $function := function-lookup(xs:QName($function-name), $arity)
    let $cache-collection := $edwebapi:cache-collection
    let $cache-file-name := substring-after($function-name, ":")||"-"
        ||translate(string-join($params?*[.!='cache'], "-"),'/','__')||".json"
    let $load-cache := util:binary-doc($cache-collection||"/"||$cache-file-name)
    let $load-from-cache := exists($load-cache)
    let $load-map := 
        if($load-from-cache) 
        then parse-json(util:binary-to-string($load-cache))
        else false()
    let $current-date-time := current-dateTime()            
    let $cache-is-new :=
        if ($load-from-cache)
        then ($current-date-time < xs:dateTime($load-map?date-time) + xs:dayTimeDuration("PT1M"))
        else false()
    let $load-from-cache := $load-from-cache and not($reload)
    let $cache-is-up-to-date :=
        if ($load-from-cache and count($node-set)=0)
        then true()
        else if ($load-from-cache)
        then
            let $since := $load-map?date-time
            let $last-modified := xmldb:find-last-modified-since($node-set, $since)
            return count($last-modified)=0
        else false()
    let $load-from-cache := ($load-from-cache and $cache-is-up-to-date) or $cache-is-new
    let $apply-and-store :=
        if ($load-from-cache)
        then ()
        else
            let $map := apply($function, $params)
            return xmldb:store($cache-collection, $cache-file-name, serialize($map,
                <output:serialization-parameters><output:method>json</output:method>
                </output:serialization-parameters>))
    let $load-map := 
        if ($load-from-cache)
        then $load-map
        else 
            let $load-cache := util:binary-doc($cache-collection||"/"||$cache-file-name)
            return parse-json(util:binary-to-string($load-cache))
    return $load-map
};

(:~
 :
 :)
declare function edwebapi:get-object(
    $app-target as xs:string,
    $object-type as xs:string, 
    $object-id as xs:string
) as map(*) 
{
    let $object-def := edwebapi:get-config($app-target)//appconf:object[@xml:id=$object-type]
    let $collection := $object-def/appconf:collection
    let $namespaces :=
        for $ns in $object-def/appconf:item/appconf:namespace
        let $prefix := $ns/@id/string()
        let $namespace-uri := $ns/string()
        return util:declare-namespace($prefix, $namespace-uri)
    let $root := $object-def/appconf:item/appconf:root
    let $id-xpath := $object-def/appconf:item/appconf:id
    let $find-expression := $id-xpath||"='"||$object-id||"'"
    let $data-collection := edwebapi:data-collection($app-target)
    let $list := edwebapi:get-objects($data-collection, $collection, $root)
    let $item := util:eval("$list["||$find-expression||"][1]")

    let $label-function := $object-def/appconf:item/appconf:label[@type=('xquery','xpath')]
    let $object-label := $object-def/appconf:item/appconf:label[@type='xpath']
    let $label :=
        if ($label-function/@type = 'xpath') 
        then util:eval-inline($item, $label-function)
        else if ($label-function/@type = 'xquery') 
        then util:eval($label-function)($item)
        else ()
    let $label :=
        if (count($label) > 1) 
        then normalize-space($label[1])
        else if (normalize-space($label) != '') 
        then normalize-space($label)
        else ("<without-title>")
    let $inner-nav :=
        for $n in $object-def/appconf:inner-navigation/appconf:navigation
        let $key := $n/@xml:id/string()
        let $xpath := $n/appconf:xpath/string()
        let $id-path := $n/appconf:id/string()
        let $label-func := $n/appconf:label-function/normalize-space()
        let $order-by := $n/appconf:order-by/string()
        let $list :=
            array {
                for $i at $pos in util:eval-inline($item, $xpath)
                let $id := util:eval-inline($i, $id-path)||""
                let $label := util:eval($label-func)($i)
                let $order := 
                    if ($order-by = "label") 
                    then $label[1]
                    else $pos
                order by $order
                return
                    map:merge((
                        map:entry("id", $id),
                        map:entry("label", $label)
                    ))
            }
        return
            map:entry(
                $key, 
                map:merge((
                    map:entry("name", $n/appconf:name/string()),
                    map:entry("xpath", $xpath),
                    map:entry("id", $id-path),
                    map:entry("order-by", $order-by),
                    map:entry("label-function", $label-func),
                    map:entry("list", $list)
                ))
            )
    let $parts :=
        let $separator := $object-def/appconf:parts/@separator/string()
        let $prefix := $object-def/appconf:parts/@prefix/string()
        let $prepath := ""
        for $part in $object-def/appconf:parts/appconf:part
            return local:get-part-map($part, $prefix, $prepath, $separator, "")
    let $xml :=
        if ($item[1]) 
        then $item[1]
        else error(xs:QName("edwebapi:get-object-001"), "Can't find "||$root||"["||$find-expression
            ||"] in collection "||$collection||" in "||$data-collection)
    let $views := 
        for $view in $object-def//appconf:views/appconf:view
        let $id := $view/@id/string()
        let $xslt := $view/appconf:xslt/string()
        let $label := $view/appconf:label/string()
        return
            map:entry (
                $id,
                map:merge((
                    map:entry("id", $id),
                    map:entry("xslt", $xslt),
                    map:entry("label", $label)
                )) 
            )
    return 
        map:merge((
            map:entry(
                "absolute-resource-id", 
                util:absolute-resource-id($item[1])
            ),
            map:entry("label", $label),
            map:entry("xml", $xml),
            map:entry("inner-nav", map:merge(( $inner-nav )) ),
            map:entry("parts", map:merge(( $parts )) ),
            map:entry("id", $object-id),
            map:entry("views", map:merge(( $views )) )
        ))
};

(:~
 : The function retrieves objects from the data.
 :
 : @param $app-target the collection name where the app is installed, e.g. /db/apps/project.WEB
 : @param $object-type the xml:id of the object-type
 : @return a map which contains "date-time", "type"="objects", "list" with an array of object
 : maps containing "id", "absolute-resource-id" "object-type", "label", "filter", "label-filter".
 :)
declare function edwebapi:get-object-list(
    $app-target as xs:string,
    $object-type as xs:string
) as map(*) 
{
    let $config := edwebapi:get-config($app-target)
    let $object-type := string($object-type)
    let $object-def := $config//appconf:object[@xml:id=$object-type]
    let $collection := $object-def/appconf:collection
    let $namespaces :=
        for $ns in $object-def/appconf:item/appconf:namespace
        let $prefix := $ns/@id/string()
        let $namespace-uri := $ns/string()
        return util:declare-namespace($prefix, $namespace-uri)
    let $root := $object-def/appconf:item/appconf:root
    let $label-function := $object-def/appconf:item/appconf:label[@type=('xquery','xpath')]
    let $object-id := $object-def/appconf:item/appconf:id/string()
    let $filters := $object-def/appconf:filters/appconf:filter
    let $filter :=
        map:merge((
            for $f at $pos in $filters
            let $key := $f/@xml:id/string()
            return
                map:entry(
                    $key, 
                    map:merge((
                        map:entry("id", $key),
                        map:entry("name", $f/appconf:name/string()),
                        map:entry("n", $pos),
                        map:entry("type", $f/appconf:type/string()),
                        map:entry("depends", $f/@depends/string()),
                        map:entry("xpath", $f/appconf:xpath/string()),
                        map:entry(
                            "label-function", 
                            $f/appconf:label-function[@type='xquery']/normalize-space()
                        )
                    ))
                )
        ))
    let $data-collection := edwebapi:data-collection($app-target)
    let $objects-xml := edwebapi:get-objects($data-collection, $collection, $root)
    let $objects := 
        for $object in $objects-xml
        let $id := string(util:eval-inline($object,$object-id))
        let $error := 
            if (count($id) != 1)
            then (error(xs:QName("edwebapi:get-object-list-001"), "There should be exact one ID for each object."
                ||" Count: "||count($id)||", ID function: "||$label-function||", Object: "
                ||serialize($object) )) 
            else ()
        let $labels := 
            if ($label-function/@type = 'xpath') 
            then array { util:eval-inline($object, $label-function) }
            else if ($label-function/@type = 'xquery') 
            then array { util:eval($label-function)($object) }
            else ()
        return
            map:merge ((
                map:entry("id", $id),
                map:entry("absolute-resource-id", util:absolute-resource-id($object)),
                map:entry("object-type", $object-type),
                map:entry(
                    "labels", $labels
                ),
                map:entry(
                    "label", $labels?1
                )
            ))
    let $objects := 
        for $o at $pos in $objects
        let $id := $o?id
        let $filter-values :=
            for $f in $filters
            let $filter-id := $f/@xml:id/string()
            let $filter-objects :=
                if ($f/@type = "relation") 
                then
                    let $rel-type-name := $f/appconf:relation/@id/string()
                    let $rel-perspective := $f/appconf:relation/@as/string()
                    let $rel-target :=
                        switch($rel-perspective)
                        case "subject" return "object"
                        case "object" return "subject"
                        default return
                            error(xs:QName("edwebapi:get-object-list-002"),
                                "Invalid configuration parameter value, only 'subject' or 'object' allowed."
                            )
                    let $relations := 
                        edwebapi:load-map-from-cache(
                            "edwebapi:get-relation-list",
                            [$app-target, $rel-type-name],
                            collection($data-collection)/*,
                            false()
                        )
                    let $items := $relations?list?*[?($rel-perspective) = $id]
                    for $i in $items return
                        switch($f/appconf:label/string())
                        case "predicate" return $i?predicate
                        case "id" return $i?($rel-target)
                        case "id+predicate" 
                        return $i?($rel-target)||"+"||$i?predicate
                        default return
                            error(xs:QName("edwebapi:get-object-list-003"),
                                "Invalid configuration parameter value, only 'id', 'predicate', and 'id+predicate' allowed."
                            )
                else if (exists($f/appconf:root[@type = 'label'])) 
                then $o?labels?*
                else util:eval-inline($objects-xml[$pos], ".//"||$f/appconf:xpath/string())
            let $filter-label-function := util:eval($f/appconf:label-function[@type='xquery'])
            return 
                map:entry(
                    $filter-id, 
                    for $fo in $filter-objects 
                    return $filter-label-function($fo)
                )
        return 
            map:merge(( 
                $o, 
                map:entry( "filter", map:merge(( $filter-values )) ) 
            ))
    let $objects := 
        for $o in $objects
        let $label-filter-values :=
            for $f in $filters[./appconf:root[@type = 'label']]
            let $filter-id := $f/@xml:id/string()
            let $filter-objects := $o?labels?*
            let $filter-label-function := util:eval($f/appconf:label-function[@type='xquery'])
            return 
                map:entry(
                    $filter-id, 
                    for $fo in $filter-objects 
                    return array { $filter-label-function($fo) }
                )
        return 
            map:entry(
                $o?id,
                map:merge(( 
                    $o, 
                    map:entry("label-filter", map:merge(( $label-filter-values )) ) 
                ))
            )
    return
        map:merge((
            map:entry("date-time", current-dateTime()),
            map:entry("type", "objects"),
            map:entry("filter", $filter),
            map:entry("list", map:merge(( $objects )) )
        ))
};

(:~
 : This function retrieves all requested objects without analyzing the filter values. This avoids
 : an endless loading loop because of relation filters and relations itself.
 :
 :)
declare function edwebapi:get-object-list-without-filter(
    $app-target as xs:string,
    $object-type as xs:string
) as map(*) 
{
    let $config := edwebapi:get-config($app-target)
    let $object-type := string($object-type)
    let $object-def := $config//appconf:object[@xml:id=$object-type]
    let $collection := $object-def/appconf:collection
    let $namespaces :=
        for $ns in $object-def/appconf:item/appconf:namespace
        let $prefix := $ns/@id/string()
        let $namespace-uri := $ns/string()
        return util:declare-namespace($prefix, $namespace-uri)
    let $root := $object-def/appconf:item/appconf:root
    let $label-function := $object-def/appconf:item/appconf:label[@type=('xquery','xpath')]
    let $object-id := $object-def/appconf:item/appconf:id/string()
    let $data-collection := edwebapi:data-collection($app-target)
    let $objects-xml := edwebapi:get-objects($data-collection, $collection, $root)
    let $objects := 
        for $object in $objects-xml
        let $id := string(util:eval-inline($object,$object-id))
        let $error := 
            if (count($id) != 1)
            then (error(xs:QName("edwebapi:get-object-list-without-filter-001"), "There should be exact one ID for each object."
                ||" Count: "||count($id)||", ID function: "||$label-function||", Object: "
                ||serialize($object) )) 
            else ()
        let $labels := 
            if ($label-function/@type = 'xpath') 
            then array { util:eval-inline($object, $label-function) }
            else if ($label-function/@type = 'xquery') 
            then array { util:eval($label-function)($object) }
            else ()
        return
            map:merge ((
                map:entry("id", $id),
                map:entry("absolute-resource-id", util:absolute-resource-id($object)),
                map:entry("object-type", $object-type),
                map:entry(
                    "labels", $labels
                ),
                map:entry(
                    "label", $labels?1
                )
            ))
    let $objects := 
        for $o in $objects
        return 
            map:entry(
                $o?id,
                map:merge(( 
                    $o
                ))
            )
    return
        map:merge((
            map:entry("date-time", current-dateTime()),
            map:entry("type", "objects"),
            map:entry("filter", map:merge(( )) ),
            map:entry("list", map:merge(( $objects )) )
        ))
};

(:~
 : Retrieves a list of objects.
 :
 : @param $data-collection the path to the project data collection
 : @param $collection the path to the collection relative to the project data collection
 : @param $root a xpath expression to the object root.
 : @return a list of nodes.
 :)
declare function edwebapi:get-objects(
    $data-collection as xs:string, 
    $collection as xs:string, 
    $root as xs:string
) as node()* 
{
    try { 
        util:eval("collection($data-collection||$collection)//"||$root)
    } 
    catch * { error(xs:QName("edwebapi:get-objects-001"), "Can't load objects. data-collection: "
        ||$data-collection||", collection: "||$collection||", root: "||$root)
        }
    (: TODO: Hack for exist-db 4.6.1 This can probably be solved more elegantly :)
    (:~ util:eval("collection('" || $collection || "')//" || $xpath) ~:)
};

(:~
 :
 :)
declare function edwebapi:order-items(
    $list as map(*)*, 
    $order as xs:string?
) as map(*)*
{
    if (not($order eq 'label'))
    then $list
    else
        let $long-list :=
            for $item in $list
            return
                for $label at $pos in $item?labels?* 
                return
                    map:merge((
                        $item,
                        map:entry(
                            "filter",
                            map:merge((
                                $item?filter,
                                map:merge((
                                    for $fk in map:keys($item?label-filter) return
                                        map:entry($fk, $item?label-filter?($fk)?*[$pos])
                                ))
                            ))
                        ),
                        map:entry("label-pos",$pos),
                        map:entry("label", $label)
                    )) 
        for $item in $long-list
        order by $item?label
        return $item
};

(:~
 :
 :)
declare function local:get-part-map(
    $part as node(), 
    $prefix as xs:string, 
    $prepath as xs:string, 
    $separator as xs:string, 
    $depends as xs:string
) 
{
    let $xmlid := $part/@xml:id/string()
    let $part-prefix :=
        concat(
            if ($prepath != "") 
            then $prepath||$separator 
            else "",
            
            if ($part/@starts-with) 
            then $part/@starts-with||$prefix 
            else ""
        )
    let $root := $part/appconf:root/string()
    let $id := $part/appconf:id/string()
    let $parts := $part/appconf:part
    let $path := $part-prefix||"<"||$xmlid||">"
    return 
        (
            map:entry(
                $xmlid, 
                map:merge((
                    map:entry("xmlid", $xmlid),
                    map:entry("path", $path),
                    map:entry("root", $root),
                    map:entry("id", $id),
                    map:entry("depends", $depends)
                ))
            ),
            if (count($parts) > 0) 
            then
                for $p in $parts
                return local:get-part-map($p, $prefix, $path, $separator, $xmlid)
            else ()
        )
};

(:~
 : Retrieves relation triples from the data.
 : 
 : @param $app-target the collection name where the app is installed, e.g. /db/apps/project.WEB
 : @param $relation-type-name the xml:id of the relation-type
 : @return a map which contains "date-time", "type"="relations", "subject-type", "object-type", 
 : "name", "list" with an array of relation maps containing "subject", "object" "predicate".
 :)
declare function edwebapi:get-relation-list(
    $app-target as xs:string, 
    $relation-type-name as xs:string
) as map(*) 
{
    let $config := edwebapi:get-config($app-target)
    let $relation-type := $config//appconf:relation[@xml:id=$relation-type-name]
    let $subject-type := $relation-type/@subject/string()
    let $object-type := $relation-type/@object/string()
    let $collection := $relation-type/appconf:collection
    let $root := $relation-type/appconf:item/appconf:root
    let $name := $relation-type/appconf:name/string()
    let $namespaces :=
        for $ns in $relation-type/appconf:item/appconf:namespace
            let $prefix := $ns/@id/string()
            let $namespace-uri := $ns/string()
            return util:declare-namespace($prefix, $namespace-uri)

    let $label-function := $relation-type/appconf:item/appconf:label[@type=('xquery','xpath')]

    let $subject-function := util:eval($relation-type/appconf:subject-condition)
    let $object-function := util:eval($relation-type/appconf:object-condition)

    let $objects :=
        let $map := 
            edwebapi:load-map-from-cache(
                "edwebapi:get-object-list-without-filter", 
                [$app-target, $object-type], 
                (), 
                false()
            )
        return $map?list?* (: "list-without-filter" :)

    let $subjects := 
        let $map := 
            edwebapi:load-map-from-cache(
                "edwebapi:get-object-list-without-filter", 
                [$app-target, $subject-type], 
                (), 
                false()
            )
        return $map?list?* (: "list-without-filter" :)
    let $data-collection := edwebapi:data-collection($app-target)
    let $relations := edwebapi:get-objects($data-collection, $collection, $root)

    let $relations :=
        for $rel in $relations
        return 
            map:merge((
                map:entry("xml", $rel),
                map:entry("absolute-resource-id", util:absolute-resource-id($rel))
            ))
    let $relations :=
        for $r in $relations
        for $s in $subjects
        where $subject-function($r, $s)
        return 
            map:merge(( $r, map:entry("subject", $s?id) ))
    let $relations :=
        for $r in $relations
        for $o in $objects
        where $object-function($r, $o)
        return 
            map:merge(( $r, map:entry("object", $o?id) ))
    let $relations :=
        for $r in $relations
        return 
            map:merge(( 
                $r, 
                map:entry(
                    "predicate", 
                    if ($label-function/@type = 'xpath') 
                    then util:eval-inline($r?xml, $label-function)
                    else if ($label-function/@type = 'xquery') 
                    then util:eval($label-function)($r?xml)
                    else ()
                )
            ))
    return
        map:merge(( 
            map:entry("date-time", current-dateTime()),
            map:entry("type", "relations"),
            map:entry("subject-type", $subject-type),
            map:entry("object-type", $object-type),
            map:entry("name", $name),
            map:entry("list", $relations )
        ))
};

(:~
 : Reads the path of the data collection from the appconf.xml.
 :
 : @param $app-target the collection name where the app is installed, e.g. /db/apps/project.WEB
 : @return the path of the data collection
 :)
declare function edwebapi:data-collection(
    $app-target as xs:string
) as xs:string
{
    let $config := edwebapi:get-config($app-target)
    return $config//appconf:project/appconf:collection/normalize-space()
};