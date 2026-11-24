import Toybox.Communications;
import Toybox.Lang;

// The one place that talks to Communications.
(:glance)
module Wire {
    // The header every watch route wants.
    function authorization() as Dictionary<String, Object> {
        return {"Authorization" => "Bearer " + ServerConfig.key()} as Dictionary<String, Object>;
    }

    // Sends request to the configured server; the callback gets (responseCode, data).
    function send(request as Request, callback as Method(responseCode as Number, data as Dictionary or String or Null) as Void) as Void {
        var headers = authorization();
        var body = {} as Dictionary<Object, Object>;
        var params = request.params;
        var audio = request.body;
        if (audio != null) {
            headers["Content-Type"] = "audio/ogg";
        } else if (params != null) {
            headers["Content-Type"] = Communications.REQUEST_CONTENT_TYPE_JSON;
            body = params as Dictionary<Object, Object>;
        }
        var options = {
            :method => request.method,
            :headers => headers,
            // DELETE and dismiss are not read: their answer is not parsed as JSON
            :responseType => request.json ? Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON : Communications.HTTP_RESPONSE_CONTENT_TYPE_TEXT_PLAIN
        };
        if (audio != null) {
            // the audio rides as the body option with no parameters, as the Computer call sends its turns
            options[:body] = audio;
            Communications.makeWebRequest(ServerConfig.url() + request.path, null, options, callback);
            return;
        }
        Communications.makeWebRequest(ServerConfig.url() + request.path, body, options, callback);
    }
}
