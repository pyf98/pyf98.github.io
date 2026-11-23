require "fileutils"
require "minitest/autorun"
require "tmpdir"
require_relative "../bin/update_scholar_citations"

class ScholarCitationsTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @path = File.join(@dir, "counts.yml")
    File.write(@path, YAML.dump("yifan" => { "missing" => 9, "blank" => 4 }))
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_updates_only_numeric_counts_for_matching_papers
    html = "<table>" + [
      row("yifan:paper", "1,234"), row("yifan:zero", "0"), row("yifan:blank", ""),
      row("other:paper", "99"), row("yifan:unlisted", "7"), row("yifan:unknown", "N/A")
    ].join + "</table>"
    ids = %w[paper zero missing blank unknown]
    capture_io { update_scholar_cache(html, author_id: "yifan", paper_ids: ids, path: @path) }
    assert_equal({ "paper" => 1234, "zero" => 0, "missing" => 9, "blank" => 4 },
                 YAML.safe_load_file(@path).fetch("yifan"))
  end

  def test_confirms_uncited_papers_using_the_complete_profile_including_unlisted_papers
    rows = row("yifan:new", "", href: "") + row("yifan:unlisted", "1,234")
    html = profile(rows, total: "1,234")
    capture_io { update_scholar_cache(html, author_id: "yifan", paper_ids: ["new"], path: @path) }
    assert_equal({ "new" => 0, "missing" => 9, "blank" => 4 }, YAML.safe_load_file(@path).fetch("yifan"))
  end

  def test_unconfirmed_empty_counts_preserve_the_cache
    rows = row("yifan:blank", "", href: "") + row("yifan:paper", "7")
    pages = [
      profile(rows, total: "8"),
      profile(rows, total: "7", more: true),
      profile(rows + row("yifan:unknown", "N/A"), total: "7")
    ]
    pages.each do |html|
      capture_io { update_scholar_cache(html, author_id: "yifan", paper_ids: %w[blank paper unknown], path: @path) }
      assert_equal({ "missing" => 9, "blank" => 4, "paper" => 7 }, YAML.safe_load_file(@path).fetch("yifan"))
    end
  end

  def test_block_page_cannot_overwrite_last_successful_snapshot
    previous = File.read(@path)
    assert_raises(RuntimeError) do
      update_scholar_cache("<html>Access temporarily unavailable</html>",
                           author_id: "yifan", paper_ids: ["missing"], path: @path)
    end
    assert_equal previous, File.read(@path)
  end

  private

  def profile(rows, total:, more: false)
    <<~HTML
      <table id="gsc_rsb_st"><tr><td>Citations</td><td>#{total}</td><td>3</td></tr></table>
      <table>#{rows}</table><button id="gsc_bpf_more" #{'disabled' unless more}>Show more</button>
    HTML
  end

  def row(key, count, href: "/scholar?cites=1")
    <<~HTML
      <tr class="gsc_a_tr">
        <td><a class="gsc_a_at" href="/citations?view_op=view_citation&amp;citation_for_view=#{key}">Paper</a></td>
        <td class="gsc_a_c"><a class="gsc_a_ac" href="#{href}">#{count}</a></td>
      </tr>
    HTML
  end
end
