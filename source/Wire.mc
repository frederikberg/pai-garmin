import Toybox.Communications;
import Toybox.Lang;

// The one place that talks to Communications.
(:glance)
module Wire {
    // Sends request to the configured server; the callback gets (responseCode, data).
    function send(request as Request, callback as Method(responseCode as Number, data as Dictionary or String or Null) as Void) as Void {
        var headers = {
            "Authorization" => "Bearer " + ServerConfig.key()
        };
        var body = {} as Dictionary<Object, Object>;
        var params = request.params;
        if (params != null) {
            headers["Content-Type"] = Communications.REQUEST_CONTENT_TYPE_JSON;
            body = params as Dictionary<Object, Object>;
        }
        var options = {
            :method => request.method,
            :headers => headers,
            // the answers that carry no body (204) are not parsed as JSON
            :responseType => request.json ? Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON : Communications.HTTP_RESPONSE_CONTENT_TYPE_TEXT_PLAIN
        };
        Communications.makeWebRequest(ServerConfig.url() + request.path, body, options, callback);
    }
}
