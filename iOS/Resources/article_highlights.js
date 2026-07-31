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

	function isIncludedTextNode(node, root) {
		if (!root || !root.contains(node)) {
			return false;
		}
		for (let element = node.parentElement; element && element !== root; element = element.parentElement) {
			if (element.matches("script, style, " + markSelector)) {
				return false;
			}
		}
		return Boolean(node.parentElement && (node.parentElement === root || root.contains(node.parentElement)));
	}

	function snapshot(root) {
		if (!root || !root.isConnected) {
			return { root, nodes: [], starts: [], rawText: "", text: "", normalizedBoundaries: [], rawToNormalized: [] };
		}
		const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
			acceptNode(node) {
				return isIncludedTextNode(node, root) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
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
		const units = [];
		const segments = new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(rawText);
		for (const segment of segments) {
			const rawStart = segment.index;
			const rawEnd = rawStart + segment.segment.length;
			if (/^\s+$/u.test(segment.segment)) {
				const previous = units[units.length - 1];
				if (previous && previous.text === " ") {
					previous.rawEnd = rawEnd;
				} else {
					units.push({ rawStart, rawEnd, text: " " });
				}
			} else {
				units.push({ rawStart, rawEnd, text: segment.segment.normalize("NFC") });
			}
		}
		while (units.length > 0 && units[0].text === " ") {
			units.shift();
		}
		while (units.length > 0 && units[units.length - 1].text === " ") {
			units.pop();
		}

		const normalizedBoundaries = [];
		const rawToNormalized = new Array(rawText.length + 1);
		let text = "";
		for (const unit of units) {
			const normalizedStart = text.length;
			const rawUnit = rawText.slice(unit.rawStart, unit.rawEnd);
			text += unit.text;
			const normalizedEnd = text.length;
			for (let offset = 0; offset <= unit.text.length; offset += 1) {
				normalizedBoundaries[normalizedStart + offset] = unit.text === rawUnit
					? unit.rawStart + offset
					: (offset === unit.text.length ? unit.rawEnd : unit.rawStart);
			}
			for (let rawOffset = unit.rawStart; rawOffset <= unit.rawEnd; rawOffset += 1) {
				rawToNormalized[rawOffset] = unit.text === rawUnit
					? normalizedStart + rawOffset - unit.rawStart
					: (rawOffset === unit.rawEnd ? normalizedEnd : normalizedStart);
			}
		}
		const firstRawOffset = units.length > 0 ? units[0].rawStart : 0;
		const lastRawOffset = units.length > 0 ? units[units.length - 1].rawEnd : rawText.length;
		for (let rawOffset = 0; rawOffset <= firstRawOffset; rawOffset += 1) {
			rawToNormalized[rawOffset] = 0;
		}
		for (let rawOffset = lastRawOffset; rawOffset <= rawText.length; rawOffset += 1) {
			rawToNormalized[rawOffset] = text.length;
		}
		return { root, nodes, starts, rawText, text, normalizedBoundaries, rawToNormalized };
	}

	function nodePath(node, root) {
		const path = [];
		for (let current = node; current && current !== root; current = current.parentNode) {
			const parent = current.parentNode;
			if (!parent) {
				return null;
			}
			path.push(Array.prototype.indexOf.call(parent.childNodes, current));
		}
		return path.reverse();
	}

	function nodeAtPath(path, root) {
		if (!Array.isArray(path) || !root) {
			return null;
		}
		let node = root;
		for (const index of path) {
			if (!Number.isInteger(index) || index < 0 || index >= node.childNodes.length) {
				return null;
			}
			node = node.childNodes[index];
		}
		return node;
	}

	function rangeFromDOMData(data, root) {
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
		const startNode = nodeAtPath(data.startPath, root);
		const endNode = nodeAtPath(data.endPath, root);
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

	function pointAtRawOffset(snapshotValue, rawOffset, bias) {
		if (snapshotValue.nodes.length === 0) {
			return null;
		}
		if (bias === "backward") {
			for (let index = 0; index < snapshotValue.nodes.length; index += 1) {
				const end = snapshotValue.starts[index] + snapshotValue.nodes[index].length;
				if (rawOffset <= end) {
					return { node: snapshotValue.nodes[index], offset: Math.max(0, rawOffset - snapshotValue.starts[index]) };
				}
			}
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
		if (!Number.isInteger(start) || !Number.isInteger(end) || start < 0 || end > snapshotValue.text.length || start >= end) {
			return null;
		}
		const startRawOffset = snapshotValue.normalizedBoundaries[start];
		const endRawOffset = snapshotValue.normalizedBoundaries[end];
		if (!Number.isInteger(startRawOffset) || !Number.isInteger(endRawOffset)) {
			return null;
		}
		const startPoint = pointAtRawOffset(snapshotValue, startRawOffset, "forward");
		const endPoint = pointAtRawOffset(snapshotValue, endRawOffset, "backward");
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
		return snapshotValue.rawToNormalized[snapshotValue.starts[index] + offset] ?? null;
	}

	function rangeIsEligible(range, root) {
		if (!root || !root.contains(range.startContainer) || !root.contains(range.endContainer)
			|| !isIncludedTextNode(range.startContainer, root) || !isIncludedTextNode(range.endContainer, root)) {
			return false;
		}
		for (const excluded of root.querySelectorAll("script, style, " + markSelector)) {
			if (range.intersectsNode(excluded)) {
				return false;
			}
		}
		const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
		for (let node = walker.nextNode(); node; node = walker.nextNode()) {
			if (range.intersectsNode(node) && !isIncludedTextNode(node, root)) {
				return false;
			}
		}
		return true;
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
			if (!mark || !state.root || !state.root.contains(mark)) {
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

	function discardResolvedState(root) {
		if (root) {
			for (const mark of Array.from(root.querySelectorAll(markSelector))) {
				const parent = mark.parentNode;
				if (!parent) {
					continue;
				}
				while (mark.firstChild) {
					parent.insertBefore(mark.firstChild, mark);
				}
				parent.removeChild(mark);
				parent.normalize();
			}
		}
		state.resolved = [];
	}

	function prepare(generation, rendition) {
		const nextRendition = String(rendition || "");
		const nextRoot = bodyRoot();
		if (state.generation !== generation || state.rendition !== nextRendition || state.root !== nextRoot) {
			discardResolvedState(state.root);
		}
		state.generation = generation;
		state.rendition = nextRendition;
		state.root = nextRoot;
		installListeners();
		return Boolean(state.root);
	}

	function captureRender() {
		return { generation: state.generation, rendition: state.rendition, root: state.root };
	}

	function renderIsCurrent(render) {
		return state.generation === render.generation && state.rendition === render.rendition
			&& state.root === render.root && Boolean(render.root && render.root.isConnected && bodyRoot() === render.root);
	}

	async function makeSelectionAnchor() {
		const render = captureRender();
		const range = selectionRange();
		if (!range || overlapsMark(range) || !rangeIsEligible(range, render.root)) {
			return null;
		}
		const selectedText = normalize(range.toString());
		if (!selectedText) {
			return null;
		}
		const snapshotValue = snapshot(render.root);
		const startOffset = normalizedOffsetForPoint(snapshotValue, range.startContainer, range.startOffset);
		const endOffset = normalizedOffsetForPoint(snapshotValue, range.endContainer, range.endOffset);
		const startPath = nodePath(range.startContainer, render.root);
		const endPath = nodePath(range.endContainer, render.root);
		if (startOffset === null || endOffset === null || !startPath || !endPath) {
			return null;
		}
		const renderedTextFingerprint = await fingerprint(snapshotValue.text);
		if (!renderIsCurrent(render)) {
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
			renditionKindRaw: render.rendition,
			renderedTextFingerprint
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

	function unwrap(mark, render) {
		const parent = mark.parentNode;
		if (!parent || !renderIsCurrent(render) || !render.root.contains(mark)) {
			return false;
		}
		while (mark.firstChild) {
			if (!renderIsCurrent(render)) {
				return false;
			}
			parent.insertBefore(mark.firstChild, mark);
		}
		if (!renderIsCurrent(render)) {
			return false;
		}
		parent.removeChild(mark);
		if (!renderIsCurrent(render)) {
			return false;
		}
		parent.normalize();
		return true;
	}

	function clearRender(render) {
		if (!renderIsCurrent(render)) {
			return false;
		}
		if (render.root) {
			for (const mark of Array.from(render.root.querySelectorAll(markSelector))) {
				if (!unwrap(mark, render)) {
					return false;
				}
			}
		}
		if (!renderIsCurrent(render)) {
			return false;
		}
		state.resolved = [];
		return true;
	}

	function clear() {
		return clearRender(captureRender());
	}

	async function restore(records) {
		const render = captureRender();
		if (!clearRender(render)) {
			return [];
		}
		const snapshotValue = snapshot(render.root);
		const renderedFingerprint = await fingerprint(snapshotValue.text);
		if (!renderIsCurrent(render)) {
			return [];
		}
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
			if (record.renditionKindRaw === render.rendition && record.renderedTextFingerprint === renderedFingerprint) {
				range = rangeFromDOMData(record.domRangeData, render.root);
				if (range && rangeIsEligible(range, render.root) && normalize(range.toString()) === selectedText) {
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
				if (!range || !rangeIsEligible(range, render.root) || normalize(range.toString()) !== selectedText) {
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
			if (!renderIsCurrent(render) || !rangeIsEligible(candidate.range, render.root)) {
				return [];
			}
			const mark = document.createElement("mark");
			if (!renderIsCurrent(render)) {
				return [];
			}
			mark.className = "nnw-saved-highlight";
			if (!renderIsCurrent(render)) {
				return [];
			}
			mark.dataset.nnwHighlightId = candidate.id;
			if (!renderIsCurrent(render)) {
				return [];
			}
			const contents = candidate.range.extractContents();
			if (!renderIsCurrent(render)) {
				return [];
			}
			mark.appendChild(contents);
			if (!renderIsCurrent(render)) {
				return [];
			}
			candidate.range.insertNode(mark);
		}
		if (!renderIsCurrent(render)) {
			return [];
		}
		state.resolved = accepted.map(candidate => ({ id: candidate.id, startOffset: candidate.start, endOffset: candidate.end }));
		return accepted.map(candidate => ({ id: candidate.id, startOffset: candidate.start, endOffset: candidate.end }));
	}

	function remove(id) {
		const render = captureRender();
		const normalizedID = String(id || "").toLowerCase();
		if (!render.root) {
			return false;
		}
		const mark = Array.from(render.root.querySelectorAll(markSelector)).find(element => element.dataset.nnwHighlightId === normalizedID);
		if (!mark) {
			return false;
		}
		if (!unwrap(mark, render) || !renderIsCurrent(render)) {
			return false;
		}
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
