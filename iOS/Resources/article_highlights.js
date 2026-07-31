(function() {
	"use strict";

	const markSelector = "mark.nnw-saved-highlight[data-nnw-highlight-id]";
	const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
	const contextLimit = 48;
	const state = {
		generation: null,
		rendition: null,
		root: null,
		listenersInstalled: false,
		resolved: []
	};

	function normalize(text) {
		return String(text || "").normalize("NFC").replace(/\s+/gu, " ").trim();
	}

	function normalizeContext(text) {
		return String(text || "").normalize("NFC").replace(/\s+/gu, " ");
	}

	function bodyRoot() {
		return document.getElementById("bodyContainer") || document.querySelector(".articleBody");
	}

	function isIncludedTextNode(node) {
		for (let element = node.parentElement; element && element !== state.root; element = element.parentElement) {
			if (element.matches("script, style, " + markSelector)) {
				return false;
			}
		}
		return Boolean(node.parentElement);
	}

	function snapshot() {
		if (!state.root || !state.root.isConnected) {
			state.root = bodyRoot();
		}
		if (!state.root) {
			return { nodes: [], starts: [], rawText: "", text: "" };
		}
		const walker = document.createTreeWalker(state.root, NodeFilter.SHOW_TEXT, {
			acceptNode(node) {
				return isIncludedTextNode(node) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
			}
		});
		const nodes = [];
		const starts = [];
		let rawText = "";
		for (let node = walker.nextNode(); node; node = walker.nextNode()) {
			starts.push(rawText.length);
			nodes.push(node);
			rawText += node.data;
		}
		return { nodes, starts, rawText, text: normalize(rawText) };
	}

	function nodePath(node) {
		const path = [];
		for (let current = node; current && current !== state.root; current = current.parentNode) {
			const parent = current.parentNode;
			if (!parent) {
				return null;
			}
			path.push(Array.prototype.indexOf.call(parent.childNodes, current));
		}
		return path.reverse();
	}

	function nodeAtPath(path) {
		if (!Array.isArray(path) || !state.root) {
			return null;
		}
		let node = state.root;
		for (const index of path) {
			if (!Number.isInteger(index) || index < 0 || index >= node.childNodes.length) {
				return null;
			}
			node = node.childNodes[index];
		}
		return node;
	}

	function rangeFromDOMData(data) {
		if (typeof data === "string") {
			try {
				data = JSON.parse(data);
			} catch (_) {
				return null;
			}
		}
		if (!data || data.version !== 1) {
			return null;
		}
		const startNode = nodeAtPath(data.startPath);
		const endNode = nodeAtPath(data.endPath);
		if (!startNode || !endNode || startNode.nodeType !== Node.TEXT_NODE || endNode.nodeType !== Node.TEXT_NODE) {
			return null;
		}
		if (data.startOffset < 0 || data.startOffset > startNode.length || data.endOffset < 0 || data.endOffset > endNode.length) {
			return null;
		}
		try {
			const range = document.createRange();
			range.setStart(startNode, data.startOffset);
			range.setEnd(endNode, data.endOffset);
			return range.collapsed ? null : range;
		} catch (_) {
			return null;
		}
	}

	function rawBoundary(snapshotValue, normalizedOffset) {
		let low = 0;
		let high = snapshotValue.rawText.length;
		while (low < high) {
			const middle = Math.floor((low + high) / 2);
			if (normalizedPrefixLength(snapshotValue.rawText.slice(0, middle)) < normalizedOffset) {
				low = middle + 1;
			} else {
				high = middle;
			}
		}
		return low;
	}

	function normalizedPrefixLength(prefix) {
		return normalize(prefix + "x").slice(0, -1).length;
	}

	function pointAtRawOffset(snapshotValue, rawOffset) {
		if (snapshotValue.nodes.length === 0) {
			return null;
		}
		for (let index = snapshotValue.nodes.length - 1; index >= 0; index -= 1) {
			if (rawOffset >= snapshotValue.starts[index]) {
				return {
					node: snapshotValue.nodes[index],
					offset: Math.min(rawOffset - snapshotValue.starts[index], snapshotValue.nodes[index].length)
				};
			}
		}
		return { node: snapshotValue.nodes[0], offset: 0 };
	}

	function rangeAtOffsets(snapshotValue, start, end) {
		const startPoint = pointAtRawOffset(snapshotValue, rawBoundary(snapshotValue, start));
		const endPoint = pointAtRawOffset(snapshotValue, rawBoundary(snapshotValue, end));
		if (!startPoint || !endPoint) {
			return null;
		}
		try {
			const range = document.createRange();
			range.setStart(startPoint.node, startPoint.offset);
			range.setEnd(endPoint.node, endPoint.offset);
			return range.collapsed ? null : range;
		} catch (_) {
			return null;
		}
	}

	function normalizedOffsetForPoint(snapshotValue, node, offset) {
		const index = snapshotValue.nodes.indexOf(node);
		if (index < 0) {
			return null;
		}
		const prefix = snapshotValue.rawText.slice(0, snapshotValue.starts[index] + offset);
		return normalizedPrefixLength(prefix);
	}

	function sha256(bytes) {
		const constants = [
			0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
			0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
			0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
			0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
			0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
			0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
			0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
			0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
		];
		const hash = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
		const message = Array.from(bytes);
		const bitLength = message.length * 8;
		message.push(0x80);
		while (message.length % 64 !== 56) {
			message.push(0);
		}
		for (let shift = 56; shift >= 0; shift -= 8) {
			message.push(Math.floor(bitLength / Math.pow(2, shift)) & 0xff);
		}
		const rotateRight = (value, amount) => (value >>> amount) | (value << (32 - amount));
		for (let offset = 0; offset < message.length; offset += 64) {
			const words = new Array(64);
			for (let index = 0; index < 16; index += 1) {
				const position = offset + index * 4;
				words[index] = ((message[position] << 24) | (message[position + 1] << 16) | (message[position + 2] << 8) | message[position + 3]) >>> 0;
			}
			for (let index = 16; index < 64; index += 1) {
				const s0 = rotateRight(words[index - 15], 7) ^ rotateRight(words[index - 15], 18) ^ (words[index - 15] >>> 3);
				const s1 = rotateRight(words[index - 2], 17) ^ rotateRight(words[index - 2], 19) ^ (words[index - 2] >>> 10);
				words[index] = (words[index - 16] + s0 + words[index - 7] + s1) >>> 0;
			}
			let [a, b, c, d, e, f, g, h] = hash;
			for (let index = 0; index < 64; index += 1) {
				const sum1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25);
				const choice = (e & f) ^ (~e & g);
				const temporary1 = (h + sum1 + choice + constants[index] + words[index]) >>> 0;
				const sum0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22);
				const majority = (a & b) ^ (a & c) ^ (b & c);
				const temporary2 = (sum0 + majority) >>> 0;
				h = g;
				g = f;
				f = e;
				e = (d + temporary1) >>> 0;
				d = c;
				c = b;
				b = a;
				a = (temporary1 + temporary2) >>> 0;
			}
			for (let index = 0; index < 8; index += 1) {
				hash[index] = (hash[index] + [a, b, c, d, e, f, g, h][index]) >>> 0;
			}
		}
		return hash.map(value => value.toString(16).padStart(8, "0")).join("");
	}

	async function fingerprint(text) {
		const bytes = new TextEncoder().encode(text);
		if (globalThis.crypto && globalThis.crypto.subtle) {
			const digest = await globalThis.crypto.subtle.digest("SHA-256", bytes);
			return "sha256:" + Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, "0")).join("");
		}
		return "sha256:" + sha256(bytes);
	}

	function selectionRange() {
		const selection = window.getSelection();
		if (!state.root || !selection || selection.rangeCount !== 1 || selection.isCollapsed) {
			return null;
		}
		const range = selection.getRangeAt(0);
		if (!state.root.contains(range.startContainer) || !state.root.contains(range.endContainer)) {
			return null;
		}
		return range;
	}

	function overlapsMark(range) {
		return Array.from(state.root ? state.root.querySelectorAll(markSelector) : []).some(mark => range.intersectsNode(mark));
	}

	function selectionState() {
		const range = selectionRange();
		const selectedText = range ? normalize(range.toString()) : "";
		return {
			hasSelection: selectedText.length > 0,
			selectedText,
			overlapsSavedHighlight: Boolean(range && overlapsMark(range))
		};
	}

	function post(name, payload) {
		const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[name];
		if (handler) {
			handler.postMessage(Object.assign({ generation: state.generation }, payload));
		}
	}

	function installListeners() {
		if (state.listenersInstalled) {
			return;
		}
		document.addEventListener("selectionchange", function() {
			post("highlightSelectionChanged", selectionState());
		});
		document.addEventListener("click", function(event) {
			const mark = event.target.closest ? event.target.closest(markSelector) : null;
			if (!mark) {
				return;
			}
			const rect = mark.getBoundingClientRect();
			post("highlightWasTapped", {
				id: mark.dataset.nnwHighlightId,
				rect: {
					x: rect.x, y: rect.y, width: rect.width, height: rect.height,
					top: rect.top, right: rect.right, bottom: rect.bottom, left: rect.left
				}
			});
		});
		state.listenersInstalled = true;
	}

	function prepare(generation, rendition) {
		state.generation = generation;
		state.rendition = String(rendition || "");
		state.root = bodyRoot();
		installListeners();
		return Boolean(state.root);
	}

	async function makeSelectionAnchor() {
		const range = selectionRange();
		if (!range || overlapsMark(range)) {
			return null;
		}
		const selectedText = normalize(range.toString());
		if (!selectedText) {
			return null;
		}
		const snapshotValue = snapshot();
		const startOffset = normalizedOffsetForPoint(snapshotValue, range.startContainer, range.startOffset);
		const endOffset = normalizedOffsetForPoint(snapshotValue, range.endContainer, range.endOffset);
		const startPath = nodePath(range.startContainer);
		const endPath = nodePath(range.endContainer);
		if (startOffset === null || endOffset === null || !startPath || !endPath) {
			return null;
		}
		return {
			selectedText,
			prefixContext: snapshotValue.text.slice(Math.max(0, startOffset - contextLimit), startOffset),
			suffixContext: snapshotValue.text.slice(endOffset, endOffset + contextLimit),
			startOffset,
			endOffset,
			domRangeData: {
				version: 1,
				startPath,
				startOffset: range.startOffset,
				endPath,
				endOffset: range.endOffset
			},
			renditionKindRaw: state.rendition,
			renderedTextFingerprint: await fingerprint(snapshotValue.text)
		};
	}

	function matchingPrefix(text, candidateStart, context) {
		let count = 0;
		for (let index = 1; index <= context.length && index <= candidateStart; index += 1) {
			if (context.charAt(context.length - index) !== text.charAt(candidateStart - index)) {
				break;
			}
			count += 1;
		}
		return count;
	}

	function matchingSuffix(text, candidateEnd, context) {
		let count = 0;
		while (count < context.length && candidateEnd + count < text.length && text.charAt(candidateEnd + count) === context.charAt(count)) {
			count += 1;
		}
		return count;
	}

	function quoteCandidate(record, snapshotValue, selectedText) {
		const candidates = [];
		for (let start = snapshotValue.text.indexOf(selectedText); start >= 0; start = snapshotValue.text.indexOf(selectedText, start + 1)) {
			const end = start + selectedText.length;
			const contextScore = matchingPrefix(snapshotValue.text, start, normalizeContext(record.prefixContext))
				+ matchingSuffix(snapshotValue.text, end, normalizeContext(record.suffixContext));
			const expected = Number.isFinite(record.startOffset) ? record.startOffset : 0;
			candidates.push({ start, end, contextScore, distance: Math.abs(start - expected) });
		}
		if (candidates.length === 1) {
			return candidates[0];
		}
		if (candidates.length < 2) {
			return null;
		}
		candidates.sort((left, right) => right.contextScore - left.contextScore || left.distance - right.distance || left.start - right.start);
		const winner = candidates[0];
		const runnerUp = candidates[1];
		if (winner.contextScore < 1 || (winner.contextScore === runnerUp.contextScore && winner.distance === runnerUp.distance)) {
			return null;
		}
		return winner;
	}

	function recordOrder(left, right) {
		const timestamp = record => Number.isFinite(record.createdAt) ? record.createdAt : (Date.parse(record.createdAt || "") || 0);
		const leftTime = timestamp(left);
		const rightTime = timestamp(right);
		return leftTime - rightTime || String(left.id || "").localeCompare(String(right.id || ""));
	}

	function unwrap(mark) {
		const parent = mark.parentNode;
		if (!parent) {
			return;
		}
		while (mark.firstChild) {
			parent.insertBefore(mark.firstChild, mark);
		}
		parent.removeChild(mark);
		parent.normalize();
	}

	function clear() {
		if (state.root) {
			Array.from(state.root.querySelectorAll(markSelector)).forEach(unwrap);
		}
		state.resolved = [];
		return true;
	}

	async function restore(records) {
		clear();
		const snapshotValue = snapshot();
		const renderedFingerprint = await fingerprint(snapshotValue.text);
		const resolved = [];
		for (const record of Array.isArray(records) ? records : []) {
			const id = String(record.id || "").toLowerCase();
			const selectedText = normalize(record.selectedText);
			if (!uuidPattern.test(id) || !selectedText) {
				continue;
			}
			let range = null;
			let start = null;
			let end = null;
			if (record.renditionKindRaw === state.rendition && record.renderedTextFingerprint === renderedFingerprint) {
				range = rangeFromDOMData(record.domRangeData);
				if (range && normalize(range.toString()) === selectedText) {
					start = normalizedOffsetForPoint(snapshotValue, range.startContainer, range.startOffset);
					end = normalizedOffsetForPoint(snapshotValue, range.endContainer, range.endOffset);
				} else {
					range = null;
				}
			}
			if (!range) {
				const candidate = quoteCandidate(record, snapshotValue, selectedText);
				if (!candidate) {
					continue;
				}
				start = candidate.start;
				end = candidate.end;
				range = rangeAtOffsets(snapshotValue, start, end);
				if (!range || normalize(range.toString()) !== selectedText) {
					continue;
				}
			}
			resolved.push({ id, start, end, range, record });
		}

		const accepted = [];
		for (const candidate of resolved.sort((left, right) => recordOrder(left.record, right.record))) {
			if (!accepted.some(existing => candidate.start < existing.end && candidate.end > existing.start)) {
				accepted.push(candidate);
			}
		}
		for (const candidate of accepted.slice().sort((left, right) => right.start - left.start || right.end - left.end)) {
			const mark = document.createElement("mark");
			mark.className = "nnw-saved-highlight";
			mark.dataset.nnwHighlightId = candidate.id;
			mark.appendChild(candidate.range.extractContents());
			candidate.range.insertNode(mark);
		}
		state.resolved = accepted.map(candidate => ({ id: candidate.id, startOffset: candidate.start, endOffset: candidate.end }));
		return accepted.map(candidate => ({ id: candidate.id, startOffset: candidate.start, endOffset: candidate.end }));
	}

	function remove(id) {
		const normalizedID = String(id || "").toLowerCase();
		if (!state.root) {
			return false;
		}
		const mark = Array.from(state.root.querySelectorAll(markSelector)).find(element => element.dataset.nnwHighlightId === normalizedID);
		if (!mark) {
			return false;
		}
		unwrap(mark);
		state.resolved = state.resolved.filter(position => position.id !== normalizedID);
		return true;
	}

	function positions() {
		return state.resolved.slice().sort((left, right) => left.startOffset - right.startOffset || left.id.localeCompare(right.id));
	}

	window.nnwHighlights = Object.freeze({
		prepare,
		selectionState,
		makeSelectionAnchor,
		restore,
		remove,
		clear,
		positions
	});
})();
