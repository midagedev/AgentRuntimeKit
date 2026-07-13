import AgentRuntimeMemory
import CAgentSQLite
import XCTest

final class MemoryStoreHardeningTests: XCTestCase {
    func testEffectiveTTLParticipatesInInMemoryUpsertEquality() async throws {
        try await assertEffectiveTTLParticipatesInEquality(store: InMemoryMemoryStore())
    }

    func testEffectiveTTLParticipatesInSQLiteUpsertEquality() async throws {
        let temporary = try TemporaryMemoryDirectory()
        let store = try SQLiteMemoryStore(url: temporary.url.appendingPathComponent("memory.sqlite"))
        try await assertEffectiveTTLParticipatesInEquality(store: store)
    }

    func testDerivedContentPatchIsRejectedButExplicitIdentityCanBePatchedInMemory() async throws {
        try await assertContentPatchIdentitySafety(store: InMemoryMemoryStore())
    }

    func testDerivedContentPatchIsRejectedButExplicitIdentityCanBePatchedInSQLite() async throws {
        let temporary = try TemporaryMemoryDirectory()
        let store = try SQLiteMemoryStore(url: temporary.url.appendingPathComponent("memory.sqlite"))
        try await assertContentPatchIdentitySafety(store: store)
    }

    func testSQLitePersistsDeduplicationKeyOriginAcrossReopen() async throws {
        let temporary = try TemporaryMemoryDirectory()
        let url = temporary.url.appendingPathComponent("memory.sqlite")
        let scope = MemoryScope.user(appID: "app", userID: "user")
        let explicitProposal = proposal(
            scope: scope,
            content: "Original explicit content",
            deduplicationKey: "stable-profile-field"
        )
        let derivedProposal = proposal(scope: scope, content: "Original derived content")

        let firstStore = try SQLiteMemoryStore(url: url)
        let explicit = try await firstStore.upsert(explicitProposal)
        let derived = try await firstStore.upsert(derivedProposal)
        try await firstStore.close()

        let reopened = try SQLiteMemoryStore(url: url)
        let fetchedExplicit = try await reopened.fetch(
            id: explicit.id,
            scope: scope,
            includeExpired: true
        )
        let fetchedDerived = try await reopened.fetch(
            id: derived.id,
            scope: scope,
            includeExpired: true
        )
        let loadedExplicit = try XCTUnwrap(fetchedExplicit)
        let loadedDerived = try XCTUnwrap(fetchedDerived)
        XCTAssertEqual(loadedExplicit.deduplicationKeyOrigin, .explicit)
        XCTAssertEqual(loadedDerived.deduplicationKeyOrigin, .derived)

        let patched = try await reopened.update(
            id: loadedExplicit.id,
            scope: scope,
            patch: MemoryPatch(content: "Updated explicit content"),
            expectedRevision: loadedExplicit.revision
        )
        XCTAssertEqual(patched.content, "Updated explicit content")
        await assertDerivedPatchRejected(
            store: reopened,
            record: loadedDerived,
            scope: scope
        )
    }

    func testInMemoryRejectsControlCharactersInScopeIdentity() async throws {
        await assertControlCharacterScopeRejected(store: InMemoryMemoryStore())
    }

    func testSQLiteRejectsControlCharactersInScopeIdentity() async throws {
        let temporary = try TemporaryMemoryDirectory()
        let store = try SQLiteMemoryStore(url: temporary.url.appendingPathComponent("memory.sqlite"))
        await assertControlCharacterScopeRejected(store: store)
    }

    func testSQLiteTextBindingPreservesEmbeddedNULInContent() async throws {
        let temporary = try TemporaryMemoryDirectory()
        let store = try SQLiteMemoryStore(url: temporary.url.appendingPathComponent("memory.sqlite"))
        let scope = MemoryScope.user(appID: "app", userID: "user")
        let content = "prefix\0suffix"

        let stored = try await store.upsert(proposal(scope: scope, content: content))
        let fetched = try await store.fetch(id: stored.id, scope: scope, includeExpired: true)

        XCTAssertEqual(fetched?.content, content)
    }

    func testSQLiteMalformedUTF8TextFailsClosed() async throws {
        let temporary = try TemporaryMemoryDirectory()
        let url = temporary.url.appendingPathComponent("memory.sqlite")
        let scope = MemoryScope.user(appID: "app", userID: "user")
        let store = try SQLiteMemoryStore(url: url)
        let stored = try await store.upsert(proposal(scope: scope, content: "valid"))
        try await store.close()

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let opened = try XCTUnwrap(database)
        defer { sqlite3_close_v2(opened) }
        let sql = "UPDATE memory_records SET content = CAST(X'80' AS TEXT) "
            + "WHERE id = '\(stored.id.uuidString)'"
        XCTAssertEqual(sqlite3_exec(opened, sql, nil, nil, nil), SQLITE_OK)

        let reopened = try SQLiteMemoryStore(url: url)
        do {
            _ = try await reopened.fetch(id: stored.id, scope: scope, includeExpired: true)
            XCTFail("Malformed UTF-8 must not be replacement-decoded into a memory record")
        } catch let error as MemoryStoreError {
            guard case .serialization = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private func assertEffectiveTTLParticipatesInEquality(store: any MemoryStore) async throws {
        let scope = MemoryScope.session(appID: "app", sessionID: "session")
        let start = Date(timeIntervalSince1970: 4_000_000)
        var expiring = proposal(scope: scope, content: "short lived")
        expiring.timeToLive = 60

        let first = try await store.upsert(expiring, at: start)
        let exactDuplicate = try await store.upsert(expiring, at: start)
        XCTAssertEqual(exactDuplicate.revision, 1)
        XCTAssertEqual(exactDuplicate.expiresAt, start.addingTimeInterval(60))

        // The effective expiry moves with the upsert timestamp, so this is a
        // material update even though the TTL duration itself is unchanged.
        let refreshed = try await store.upsert(expiring, at: start.addingTimeInterval(10))
        XCTAssertEqual(refreshed.id, first.id)
        XCTAssertEqual(refreshed.revision, 2)
        XCTAssertEqual(refreshed.expiresAt, start.addingTimeInterval(70))

        var persistent = expiring
        persistent.timeToLive = nil
        let expiryRemoved = try await store.upsert(
            persistent,
            expectedRevision: 2,
            at: start.addingTimeInterval(10)
        )
        XCTAssertEqual(expiryRemoved.revision, 3)
        XCTAssertNil(expiryRemoved.expiresAt)
    }

    private func assertControlCharacterScopeRejected(store: any MemoryStore) async {
        let invalidScopes: [MemoryScope] = [
            .user(appID: "app", userID: "user\0other"),
            MemoryScope(level: .application, appID: "app", userID: ""),
            .user(appID: "app", userID: " user "),
            .user(appID: "app", userID: "e\u{301}"),
        ]
        for scope in invalidScopes {
            do {
                _ = try await store.upsert(proposal(scope: scope, content: "must fail"))
                XCTFail("Non-canonical scope identity must fail before storage")
            } catch let error as MemoryStoreError {
                guard case .invalidScope = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private func assertContentPatchIdentitySafety(store: any MemoryStore) async throws {
        let scope = MemoryScope.user(appID: "app", userID: "user")
        let derived = try await store.upsert(proposal(
            scope: scope,
            content: "Derived identity content"
        ))
        XCTAssertEqual(derived.deduplicationKeyOrigin, .derived)
        await assertDerivedPatchRejected(store: store, record: derived, scope: scope)

        let fetchedUnchanged = try await store.fetch(
            id: derived.id,
            scope: scope,
            includeExpired: true
        )
        let unchanged = try XCTUnwrap(fetchedUnchanged)
        XCTAssertEqual(unchanged.content, derived.content)
        XCTAssertEqual(unchanged.revision, derived.revision)

        let replacement = try await store.upsert(proposal(
            scope: scope,
            content: "A new derived identity"
        ))
        XCTAssertNotEqual(replacement.id, derived.id)

        let explicit = try await store.upsert(proposal(
            scope: scope,
            content: "Explicit identity content",
            deduplicationKey: "stable-key"
        ))
        XCTAssertEqual(explicit.deduplicationKeyOrigin, .explicit)
        let patched = try await store.update(
            id: explicit.id,
            scope: scope,
            patch: MemoryPatch(content: "Explicit identity updated"),
            expectedRevision: explicit.revision
        )
        XCTAssertEqual(patched.id, explicit.id)
        XCTAssertEqual(patched.content, "Explicit identity updated")
        XCTAssertEqual(patched.deduplicationKey, explicit.deduplicationKey)
    }

    private func assertDerivedPatchRejected(
        store: any MemoryStore,
        record: MemoryRecord,
        scope: MemoryScope
    ) async {
        do {
            _ = try await store.update(
                id: record.id,
                scope: scope,
                patch: MemoryPatch(content: "Mutated behind derived identity"),
                expectedRevision: record.revision
            )
            XCTFail("A content-derived deduplication identity must not survive a content patch")
        } catch let error as MemoryStoreError {
            XCTAssertEqual(error, .contentPatchRequiresExplicitDeduplicationKey(record.id))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func proposal(
        scope: MemoryScope,
        content: String,
        deduplicationKey: String? = nil
    ) -> MemoryProposal {
        MemoryProposal(
            scope: scope,
            kind: .fact,
            content: content,
            provenance: MemoryProvenance(
                source: "hardening-test",
                sourceID: "stable-source",
                capturedAt: Date(timeIntervalSince1970: 3_999_000)
            ),
            deduplicationKey: deduplicationKey
        )
    }
}

private final class TemporaryMemoryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentRuntimeMemoryHardeningTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
