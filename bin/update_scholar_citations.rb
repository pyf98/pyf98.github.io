#!/usr/bin/env ruby

require "bibtex"
require "date"
require "nokogiri"
require "open-uri"
require "tempfile"
require "yaml"

def parse_scholar_count(text)
  digits = text.to_s.strip
  Integer(digits.delete(","), 10) if digits.match?(/\A(?:\d+|\d{1,3}(?:,\d{3})+)\z/)
end

def scholar_profile_counts(html, author_id)
  profile = Nokogiri::HTML(html)
  rows = profile.css("tr.gsc_a_tr")
  counts = {}
  rows.each do |row|
    href = row.at_css("a.gsc_a_at[href]")&.[]("href")
    next unless href

    query = URI.decode_www_form(URI.parse(href).query.to_s).to_h
    owner, paper_id = query["citation_for_view"].to_s.split(":", 2)
    next unless owner == author_id && !paper_id.to_s.empty?

    link = row.at_css("td.gsc_a_c a.gsc_a_ac")
    next unless link

    label = link.text.strip
    count = parse_scholar_count(label)
    counts[paper_id] = count if count || (label.empty? && link["href"] == "")
  end

  # Scholar leaves an uncited paper's count and link empty. Confirm those zeros
  # only when every row is accounted for and the counts add up to the all-time total.
  total = profile.at_xpath("//table[@id='gsc_rsb_st']//tr[normalize-space(td[1])='Citations']/td[2]")
  if profile.at_css("#gsc_bpf_more[disabled]") && counts.size == rows.size && counts.values.compact.sum == parse_scholar_count(total&.text)
    counts.transform_values! { |count| count || 0 }
  end
  counts.compact
end

def update_scholar_cache(html, author_id:, paper_ids:, path:)
  verified = scholar_profile_counts(html, author_id).slice(*paper_ids)
  raise "Google Scholar returned no verified counts for the configured papers" if verified.empty?

  cache = File.exist?(path) ? YAML.safe_load_file(path) : {}
  previous = cache.fetch(author_id, {})
  counts = previous.merge(verified)
  if counts != previous
    cache[author_id] = counts.sort.to_h
    Tempfile.create([".scholar-citations", ".tmp"], File.dirname(path)) do |file|
      file.write(YAML.dump(cache))
      file.close
      File.rename(file.path, path)
    end
  end

  missing = paper_ids - verified.keys
  warn "No verified count this time for: #{missing.join(', ')}" unless missing.empty?
  puts "Verified #{verified.size} of #{paper_ids.size} Google Scholar citation counts."
end

if $PROGRAM_NAME == __FILE__
  config = YAML.safe_load_file("_config.yml", permitted_classes: [Date])
  author_id = YAML.safe_load_file("_data/socials.yml").fetch("scholar_userid")
  scholar = config.fetch("scholar")
  bibliography = BibTeX.open(File.join(".", scholar.fetch("source"), scholar.fetch("bibliography")))
  paper_ids = bibliography.entries.values.filter_map { |entry| entry[:google_scholar_id]&.to_s }.uniq
  exit if paper_ids.empty?

  # Read one public profile page per refresh. Ordinary Jekyll builds only read the cache.
  profile = URI("https://scholar.google.com/citations")
  profile.query = URI.encode_www_form(user: author_id, hl: "en", pagesize: 100)
  URI.open(profile, "User-Agent" => "academic-homepage-citations/1.0 (+#{config.fetch('url')}/)",
           open_timeout: 10, read_timeout: 20) do |response|
    update_scholar_cache(response, author_id: author_id, paper_ids: paper_ids, path: "_data/scholar_citations.yml")
  end
end
