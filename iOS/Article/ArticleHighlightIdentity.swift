import CryptoKit
import Foundation

enum ArticleHighlightIdentity {
	static func articleKey(feedURL: String?, uniqueID: String?) -> String? {
		guard let feedURL, !feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
			let uniqueID, !uniqueID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			return nil
		}

		let payload = "\(feedURL.utf8.count):\(feedURL)\(uniqueID.utf8.count):\(uniqueID)"
		let digest = SHA256.hash(data: Data(payload.utf8))
		return "nnw-feed-article:v1:" + digest.map { String(format: "%02x", $0) }.joined()
	}
}
