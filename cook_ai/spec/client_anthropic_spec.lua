local stub = require("spec.cook_stub")

describe("client.anthropic", function()
    local client
    before_each(function()
        stub.reset()
        package.loaded["cook_ai.client.anthropic"] = nil
        client = require("cook_ai.client.anthropic")
    end)

    it("builds /v1/messages payload with system + user + model + max_tokens", function()
        local body = client._build_payload({
            model       = "claude-sonnet-4-6",
            system      = "You are a translator.",
            user        = "Translate: hello",
            max_tokens  = 1024,
            temperature = 0,
        })
        assert.equals("claude-sonnet-4-6", body.model)
        assert.equals("You are a translator.", body.system)
        assert.equals(1024, body.max_tokens)
        assert.equals(0, body.temperature)
        assert.equals("user", body.messages[1].role)
        assert.equals("Translate: hello", body.messages[1].content)
    end)

    it("appends tools/response_format when supplied", function()
        local body = client._build_payload({
            model = "m", system = "s", user = "u", max_tokens = 1,
            response_format = { type = "json_schema", schema = { type = "object" } },
            tools = { { name = "calc", description = "x", input_schema = {} } },
        })
        assert.same({ type = "object" }, body.response_format.schema)
        assert.equals("calc", body.tools[1].name)
    end)

    it("curl_cmd quotes header and writes payload to stdin via @-", function()
        local cmd = client._curl_cmd({
            api_key   = "sk-test",
            timeout_s = 30,
            payload_path = "/tmp/x.json",
        })
        assert.matches("x%-api%-key: sk%-test", cmd)
        assert.matches("anthropic%-version: 2023%-06%-01", cmd)
        assert.matches("--max%-time 30", cmd)
        assert.matches("--data%-binary @/tmp/x.json", cmd)
        assert.matches("https://api.anthropic.com/v1/messages", cmd)
    end)

    it("extract_text pulls content[1].text from a normal response", function()
        local resp = {
            content = { { type = "text", text = "Bonjour" } },
            stop_reason = "end_turn",
        }
        assert.equals("Bonjour", client._extract_text(resp))
    end)

    it("extract_text errors on non-text stop_reason", function()
        local resp = { content = {}, stop_reason = "max_tokens" }
        assert.has_error(function() client._extract_text(resp) end)
    end)

    it("curl_cmd honours opts.endpoint override", function()
        local cmd = client._curl_cmd({
            api_key   = "sk-test",
            timeout_s = 30,
            payload_path = "/tmp/x.json",
            endpoint  = "https://proxy.example.com/v1/messages",
        })
        assert.matches("https://proxy%.example%.com/v1/messages", cmd)
        assert.no_matches("api%.anthropic%.com", cmd)
    end)
end)
