#!/usr/bin/env python3
"""Verify the actual shared metadata resolver without launching the player."""
from pathlib import Path
import subprocess
root = Path(__file__).resolve().parents[1]
source = (root / 'PlayerSystem/PlayQueueView.swift').read_text()
model = source[source.index('struct MediaNFOMetadata:'):source.index('actor MediaNFOCache')]
info = (root / 'native/Player/Modern/VideoInformation.swift').read_text()
resolver = info[info.index('enum CurrentMediaMetadataResolver {'):]
online = (root / 'PlayerSystem/OnlineMovieMetadata.swift').read_text()
online = online[online.index('struct OnlineMovie:'):online.index('struct MovieMetadataError:')]
out = root / 'build/checks/current-metadata'
out.mkdir(parents=True, exist_ok=True)
fixture = r'''
var nfo = MediaNFOMetadata()
nfo.title = "NFO title"
nfo.genres = ["Drama"]
nfo.rating = 7.5
let result = CurrentMediaMetadataResolver.resolve(nfo: nfo,
    raw: ["TITLE": "Embedded title", "director": "A / B", "DATE": "2024-01-01", "genre": "Comedy"],
    fallbackTitle: "filename")
precondition(result.title == "NFO title" && result.genres == ["Drama"])
precondition(result.directors == ["A", "B"] && result.year == "2024" && result.rating == 7.5)
let fallback = CurrentMediaMetadataResolver.resolve(nfo: nil, raw: ["date": "invalid"], fallbackTitle: "filename")
precondition(fallback.title == "filename" && fallback.year.isEmpty)
let query = MovieFilenameQuery.parse("Arrival.2016.1080p.BluRay.mkv")
precondition(query.title == "Arrival" && query.year == "2016")
precondition(MovieFilenameQuery.parse("1917.mkv").year == nil)
precondition(MovieFilenameQuery.parse("Blade.Runner.2049.1080p.mkv").title == "Blade Runner 2049")
precondition(MovieFilenameQuery.episode("Example.Show.S02E03.1080p.mkv")?.season == 2)
precondition(MovieFilenameQuery.episode("Example.Show.S02E03.1080p.mkv")?.title == "Example Show")
precondition(MovieFilenameQuery.episode("Example 1x04.mkv")?.episode == 4)
precondition(MovieFilenameQuery.episode("Example.S00E01.mkv")?.season == 0)
precondition(MovieFilenameQuery.episode("Example.S01E02E03.mkv") == nil)
precondition(MovieFilenameQuery.episode("Example.S01E02-03.mkv") == nil)
precondition(MovieFilenameQuery.episode("Movie.2024.1080p.mkv") == nil)
let batch = EpisodeBatchFile.candidates(paths: ["/show/Show.S01E03.mkv", "/show/Show.S01E01.mkv", "/show/Show.S01E03.mkv", "/show/Other.S01E02.mkv", "/show/Show.S01E02.srt", "https://example.org/Show.S01E05.mkv"], anchor: "/show/Show.S01E01.mkv")
precondition(batch.map { $0.key.episode } == [1, 3])
precondition(EpisodeBatchFile.candidates(paths: ["/show/Show.2024.S01E02.mkv"], anchor: "/show/Show.2020.S01E01.mkv").isEmpty)
let movie = OnlineMovie(id: 1, title: "Online title", originalTitle: "Original", releaseDate: "2020-01-01", overview: "Online plot", runtime: 120, genres: [.init(name: "Science Fiction")], credits: nil)
var decorated = movie
decorated.posterPath = "/poster_123.jpg"
decorated.productionCompanies = [.init(name: "Studio")]
precondition(decorated.posterURL?.host == "image.tmdb.org")
precondition(CurrentMediaMetadataResolver.resolve(nfo: nil, raw: [:], fallbackTitle: "file", online: decorated).studio == "Studio")
decorated.posterPath = "/../secret.jpg"
precondition(decorated.posterURL == nil)
let roundtrip = try! JSONDecoder().decode(OnlineMovie.self, from: JSONEncoder().encode(decorated))
precondition(roundtrip.productionCompanies?.first?.name == "Studio")
let legacy = try! JSONDecoder().decode(OnlineMovie.self, from: Data(#"{"id":1,"title":"Legacy"}"#.utf8))
precondition(legacy.seriesID == nil && legacy.detailsURL.path == "/movie/1")
decorated.seriesID = 42; decorated.seasonNumber = 0; decorated.episodeNumber = 3
let episodeRoundtrip = try! JSONDecoder().decode(OnlineMovie.self, from: JSONEncoder().encode(decorated))
precondition(episodeRoundtrip.detailsURL.path == "/tv/42/season/0/episode/3")
precondition(movie.searchHint("Online")?.contains("Online title") == true)
precondition(movie.searchHint("Science")?.contains("Science Fiction") == true)
precondition(movie.searchHint("unfindable") == nil)
let merged = CurrentMediaMetadataResolver.resolve(nfo: nfo, raw: ["description":"Embedded plot"], fallbackTitle: "file", online: movie)
precondition(merged.title == "NFO title" && merged.plot == "Embedded plot" && merged.year == "2020")
precondition(merged.originalTitle == "Original" && merged.runtimeMinutes == 120 && merged.genres == ["Drama"])
precondition(movie.durationDifference(7200) == 0 && movie.durationDifference(.nan) == nil)
let unknown = OnlineMovie(id: 2, title: "Unknown", originalTitle: nil, releaseDate: nil, overview: nil, runtime: nil, genres: nil, credits: nil)
precondition(MovieFilenameQuery.ordered([unknown,movie], seconds: 7100).map(\.id) == [1,2])
print("PASS: filename cleanup, numeric titles, duration ranking, online gap filling and local precedence")
print("PASS: NFO precedence, embedded gap filling, fallback title and invalid year")
'''
swift = out / 'check.swift'
swift.write_text('import Foundation\n' + online + model + resolver + fixture)
subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-module-cache-path', str(out / 'cache'), str(swift), '-o', str(out / 'check')], check=True)
subprocess.run([str(out / 'check')], check=True)
