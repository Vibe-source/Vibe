defmodule Vibe.AgentEventAttachmentsTest do
  use ExUnit.Case, async: true

  alias Vibe.AI.AgentEventRuntime

  test "normalizes frozen nested cargo attachment fields" do
    assert %{"items" => [image, pdf]} =
             AgentEventRuntime.normalize_event_attachments(%{
               "data" => %{
                 "attachments" => [
                   %{
                     "type" => "image",
                     "title" => "Cargo sheet",
                     "filename" => "123456.png",
                     "mime" => "image/png",
                     "url" => "https://example.test/123456.png"
                   },
                   %{
                     "type" => "pdf",
                     "filename" => "123456.pdf",
                     "mime" => "application/pdf",
                     "url" => "https://example.test/123456.pdf"
                   }
                 ]
               }
             })

    assert image["name"] == "123456.png"
    assert image["mimeType"] == "image/png"
    assert image["caption"] == "Cargo sheet"
    assert pdf["name"] == "123456.pdf"
    assert pdf["mimeType"] == "application/pdf"
  end

  test "keeps top-level attachments compatible and merges nested attachments" do
    assert %{"items" => [top, nested]} =
             AgentEventRuntime.normalize_event_attachments(%{
               "attachments" => [
                 %{"type" => "image", "url" => "https://example.test/top.png"}
               ],
               "payload" => %{
                 "attachments" => [
                   %{"type" => "html", "url" => "https://example.test/print.html"}
                 ]
               }
             })

    assert top["type"] == "image"
    assert nested["type"] == "html"
  end
end
