# openclaw-config.nix — OpenClaw's openclaw.json, rendered from build.json.
#
# A pure function of buildJson (builtins only, no nixpkgs), so flake.nix emits
# it as dist/configs/openclaw.json and test-openclaw-service.mjs evaluates the
# very same expression with nix-instantiate. Nothing here restates a value
# build.json holds: the port, model, provider and bind all come from there.
{ buildJson }:

let
  rt = buildJson.runtime;
  p  = rt.provider;
in
{
  gateway = {
    mode = "local";
    port = buildJson.ports.app;
    bind = rt.bind;
    auth = { mode = rt.auth; };
    tailscale = { mode = "off"; };
    # No browser UI: nothing reaches this listener but the fleet gateway.
    controlUi = { enabled = false; };
    http = { endpoints = { chatCompletions = { enabled = true; }; }; };
  };
  models = {
    providers = {
      ${p.id} = {
        baseUrl = p.base_url;
        apiKey = p.api_key_placeholder;
        api = p.api;
        models = [
          {
            id = rt.model;
            name = "${rt.model} (fleet gateway)";
            reasoning = false;
            input = [ "text" ];
            contextWindow = p.context_window;
            maxTokens = p.max_tokens;
          }
        ];
      };
    };
  };
  agents = {
    defaults = {
      model = { primary = "${p.id}/${rt.model}"; };
    };
  };
}
