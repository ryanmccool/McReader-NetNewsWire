import Foundation

struct ArticleHighlightMarkdownSnapshot {
	let resolvedOffsets: [UUID: Int]
	let resolvedRichText: [UUID: NetNewsWireHighlightRichText]

	static func validated(
		from value: Any?,
		expectedState: ArticleHighlightRenderState
	) -> ArticleHighlightMarkdownSnapshot? {
		guard let value = value as? [String: Any],
			let generation = (value["generation"] as? NSNumber)?.uint64Value,
			let articleKey = value["articleKey"] as? String,
			let rendition = value["rendition"] as? String,
			generation == expectedState.generation,
			articleKey == expectedState.articleKey,
			rendition == expectedState.rendition.rawValue,
			let positions = value["positions"] as? [[String: Any]],
			let richText = value["richText"] as? [[String: Any]] else {
			return nil
		}
		return ArticleHighlightMarkdownSnapshot(
			resolvedOffsets: Self.positions(from: positions),
			resolvedRichText: Self.richText(from: richText)
		)
	}

	private static func positions(from values: [[String: Any]]) -> [UUID: Int] {
		Dictionary(uniqueKeysWithValues: values.compactMap { position in
			guard let idString = position["id"] as? String,
				let id = UUID(uuidString: idString),
				let offset = (position["startOffset"] as? NSNumber)?.intValue else { return nil }
			return (id, offset)
		})
	}

	private static func richText(from values: [[String: Any]]) -> [UUID: NetNewsWireHighlightRichText] {
		Dictionary(uniqueKeysWithValues: values.compactMap { item in
			guard let idString = item["id"] as? String,
				let id = UUID(uuidString: idString),
				let selectedText = item["selectedText"] as? String,
				let html = item["html"] as? String,
				let baseURLString = item["baseURL"] as? String,
				let baseURL = URL(string: baseURLString) else { return nil }
			return (
				id,
				NetNewsWireHighlightRichText(
					id: id, selectedText: selectedText, html: html, baseURL: baseURL
				)
			)
		})
	}
}

enum ArticleHighlightMarkdown {
	static func orderedRecords(
		records: [NetNewsWireHighlightRecord],
		resolvedOffsets: [UUID: Int]
	) -> [NetNewsWireHighlightRecord] {
		records.sorted { lhs, rhs in
			let lhsOffset = resolvedOffsets[lhs.id]
			let rhsOffset = resolvedOffsets[rhs.id]

			switch (lhsOffset, rhsOffset) {
			case let (.some(lhsOffset), .some(rhsOffset)) where lhsOffset != rhsOffset:
				return lhsOffset < rhsOffset
			case (.some, .none):
				return true
			case (.none, .some):
				return false
			default:
				if lhs.createdAt != rhs.createdAt {
					return lhs.createdAt < rhs.createdAt
				}
				return lhs.id.uuidString < rhs.id.uuidString
			}
		}
	}

	static func quotation(
		records: [NetNewsWireHighlightRecord],
		resolvedOffsets: [UUID: Int]
	) -> String? {
		let selections = orderedRecords(records: records, resolvedOffsets: resolvedOffsets).compactMap { record -> String? in
			let selection = record.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
			return selection.isEmpty ? nil : selection
		}

		guard !selections.isEmpty else {
			return nil
		}
		return selections.joined(separator: "\n\n")
	}

	static func richText(
		records: [NetNewsWireHighlightRecord],
		resolvedOffsets: [UUID: Int],
		resolvedRichText: [UUID: NetNewsWireHighlightRichText]
	) -> [NetNewsWireHighlightRichText] {
		orderedRecords(records: records, resolvedOffsets: resolvedOffsets).compactMap { record in
			let selectedText = record.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !selectedText.isEmpty else { return nil }
			let resolved = resolvedRichText[record.id]
			return NetNewsWireHighlightRichText(
				id: record.id,
				selectedText: selectedText,
				html: resolved?.html,
				baseURL: resolved?.baseURL
			)
		}
	}
}
