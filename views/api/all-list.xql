xquery version "3.1";

import module namespace edwebapi="http://www.bbaw.de/telota/software/ediarum/web/api";

declare namespace output = "http://www.w3.org/2010/xslt-xquery-serialization";
declare namespace tei = "http://www.tei-c.org/ns/1.0";
            
declare option output:method "json";
declare option output:media-type "application/json";

let $app-target := request:get-parameter("app-target", request:get-attribute("app-target"))
let $limit := request:get-parameter("limit", request:get-attribute("limit"))
let $cache := request:get-parameter("cache", request:get-attribute("cache"))

let $id := request:get-parameter("id", request:get-attribute("id"))
let $id-type := request:get-parameter("id-type", request:get-attribute("id-type"))

let $id-type :=
    if ($id-type||"" = "")
    then $id
    else $id-type

(: let $id-type := request:get-parameter("id-type", request:get-attribute("id-type")) :)
return 
    if ($id-type = "all")
    then
        let $all-list := edwebapi:get-all($app-target, $limit, $cache, false())
        return $all-list
    else if ($id-type = "complete")
    then
        let $all-list := edwebapi:get-all($app-target, $limit, $cache, true())
        return map:remove($all-list, "date-time")
    else
        let $all-list := edwebapi:get-all($app-target, $limit, $cache, true())
        return map:remove($all-list, "date-time")?*[?filter?($id-type)||"" != ""]
