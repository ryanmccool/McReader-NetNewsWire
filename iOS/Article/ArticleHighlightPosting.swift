import Foundation

enum ArticleHighlightPosting {
	static func quotation(
		records: [NetNewsWireHighlightRecord],
		resolvedOffsets: [UUID: Int]
	) -> String? {
		let selections = records.sorted { lhs, rhs in
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
		}.compactMap { record -> String? in
			let selection = record.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
			return selection.isEmpty ? nil : selection
		}

		guard !selections.isEmpty else {
			return nil
		}
		return selections.joined(separator: "\n\n")
	}
}
