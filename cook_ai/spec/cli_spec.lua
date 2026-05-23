require("spec.cook_stub")

describe("bin/cook_ai_call argv parser", function()
    local cli
    before_each(function()
        package.loaded["cook_ai.cli"] = nil
        cli = require("cook_ai.cli")
    end)

    it("parses required flags", function()
        local args = cli.parse_args({
            "--provider", "anthropic",
            "--model",    "claude-sonnet-4-6",
            "--system-file", "/tmp/sys.txt",
            "--user-file",   "/tmp/usr.txt",
            "--output",      "/tmp/out.md",
            "--payload-tmp", "/tmp/payload.json",
        })
        assert.equals("anthropic", args.provider)
        assert.equals("claude-sonnet-4-6", args.model)
        assert.equals("/tmp/sys.txt", args.system_file)
        assert.equals("/tmp/usr.txt", args.user_file)
        assert.equals("/tmp/out.md", args.output)
        assert.equals("/tmp/payload.json", args.payload_tmp)
    end)

    it("parses optional --max-tokens / --temperature / --response-format-json", function()
        local args = cli.parse_args({
            "--provider","anthropic","--model","m",
            "--system-file","s","--user-file","u",
            "--output","o","--payload-tmp","p",
            "--max-tokens","4096",
            "--temperature","0",
            "--response-format-json", '{"type":"text"}',
        })
        assert.equals(4096, args.max_tokens)
        assert.equals(0, args.temperature)
        assert.same({ type = "text" }, args.response_format)
    end)

    it("rejects missing required flag", function()
        assert.has_error(function()
            cli.parse_args({ "--model", "m" })
        end)
    end)
end)
