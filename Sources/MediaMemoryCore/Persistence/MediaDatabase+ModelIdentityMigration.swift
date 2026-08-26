import Foundation

extension MediaDatabase {
    /// Converts schema-1 model labels to endpoint-aware identities in place.
    ///
    /// The evidence payloads did not change format between the two schemas, so
    /// relabelling an exact legacy pipeline match is both safer and cheaper than
    /// invoking the models again. A persistent marker makes the necessarily
    /// ambiguous bare-ID adoption a one-time upgrade decision.
    @discardableResult
    public func migrateLegacyModelIdentities(
        configuration: ModelConfiguration,
        allowLegacyAdoption: Bool,
        now: Date = Date()
    ) throws -> Bool {
        let markerKey = "model-derivation-identity-v2"
        let legacyInputVersion = SegmentIndexer.legacyInputVersion(for: configuration)
        let currentInputVersion = SegmentIndexer.inputVersion(for: configuration)
        let migratedCheckpoint = #"{"stage":"identity_migrated"}"#

        return try connection.inTransaction {
            let marker = try connection.prepare(
                "SELECT 1 FROM application_metadata WHERE key = ?"
            )
            try marker.bind(.text(markerKey), at: 1)
            guard !(try marker.step()) else { return false }
            guard allowLegacyAdoption else {
                try recordModelIdentityMigration(
                    key: markerKey,
                    value: currentInputVersion
                )
                return true
            }

            // Only an exact schema-1 fingerprint match is eligible. Results
            // produced by a genuinely different model or pipeline remain stale
            // and will be handled by normal queue reconciliation.
            let embeddings = try connection.prepare(
                """
                UPDATE segment_embedding
                SET model_id = ?, input_version = ?
                WHERE model_id = ? AND input_version = ?
                """
            )
            try embeddings.bind(.text(configuration.embedding.derivationID), at: 1)
            try embeddings.bind(.text(currentInputVersion), at: 2)
            try embeddings.bind(.text(configuration.embedding.modelID), at: 3)
            try embeddings.bind(.text(legacyInputVersion), at: 4)
            _ = try embeddings.step()

            try migrateSiblingRunModelID(
                kind: "asr",
                legacyID: configuration.asr.modelID,
                currentID: configuration.asr.derivationID,
                embeddingModelID: configuration.embedding.derivationID,
                inputVersion: currentInputVersion
            )
            try migrateSiblingRunModelID(
                kind: "alignment",
                legacyID: configuration.aligner.modelID,
                currentID: configuration.aligner.derivationID,
                embeddingModelID: configuration.embedding.derivationID,
                inputVersion: currentInputVersion
            )

            let embeddingRuns = try connection.prepare(
                """
                UPDATE derivation_run
                SET model_id = ?
                WHERE kind = 'embedding' AND model_id = ?
                  AND id IN (
                      SELECT derivation_run_id
                      FROM segment_embedding
                      WHERE model_id = ? AND input_version = ?
                  )
                """
            )
            try embeddingRuns.bind(.text(configuration.embedding.derivationID), at: 1)
            try embeddingRuns.bind(.text(configuration.embedding.modelID), at: 2)
            try embeddingRuns.bind(.text(configuration.embedding.derivationID), at: 3)
            try embeddingRuns.bind(.text(currentInputVersion), at: 4)
            _ = try embeddingRuns.step()

            // A user may have opened the transitional build long enough for a
            // few evidence jobs to commit. Rebuild each compatible description
            // fingerprint from the currently committed atomic evidence revision
            // and adopt it instead of sending the same frames to a model again.
            let descriptionQuery = try connection.prepare(
                """
                SELECT d.segment_id, d.derivation_run_id, d.prompt_version,
                       e.derivation_run_id, d.input_version
                FROM segment_description d
                JOIN derivation_run dr ON dr.id = d.derivation_run_id
                JOIN segment_embedding e ON e.segment_id = d.segment_id
                JOIN segment s ON s.id = d.segment_id
                JOIN media_asset a ON a.id = s.asset_id
                WHERE dr.kind = 'description'
                  AND dr.model_id = ?
                  AND dr.status = 'succeeded'
                  AND dr.source_fingerprint = a.fingerprint
                  AND d.prompt_version = ?
                  AND e.model_id = ? AND e.input_version = ?
                  AND a.status = 'ready'
                  AND a.invalidated_at IS NULL
                  AND a.is_excluded = 0
                  AND s.is_active = 1
                ORDER BY d.segment_id
                """
            )
            try descriptionQuery.bind(.text(configuration.description.modelID), at: 1)
            try descriptionQuery.bind(.text(DescriptionService.promptVersion), at: 2)
            try descriptionQuery.bind(.text(configuration.embedding.derivationID), at: 3)
            try descriptionQuery.bind(.text(currentInputVersion), at: 4)

            var descriptions: [(
                segmentID: String,
                runID: String,
                promptVersion: String,
                evidenceRevision: String,
                storedInputVersion: String
            )] = []
            while try descriptionQuery.step() {
                guard let segmentID = descriptionQuery.text(at: 0),
                      let runID = descriptionQuery.text(at: 1),
                      let promptVersion = descriptionQuery.text(at: 2),
                      let evidenceRevision = descriptionQuery.text(at: 3),
                      let storedInputVersion = descriptionQuery.text(at: 4) else {
                    continue
                }
                descriptions.append(
                    (segmentID, runID, promptVersion, evidenceRevision, storedInputVersion)
                )
            }

            for description in descriptions {
                guard let context = try searchContext(segmentID: description.segmentID) else {
                    continue
                }
                let frames = try segmentFrames(segmentID: description.segmentID)
                guard !frames.isEmpty else { continue }
                let legacyDescriptionInputVersion = DescriptionService.inputVersion(
                    context: context,
                    frames: frames,
                    modelID: configuration.description.modelID
                )
                guard description.storedInputVersion == legacyDescriptionInputVersion else {
                    // The transitional build has already committed different
                    // evidence, or this description was stale before upgrade.
                    // Keep it visible but do not claim it belongs to new input.
                    continue
                }
                let inputVersion = DescriptionService.inputVersion(
                    context: context,
                    frames: frames,
                    modelID: configuration.description.derivationID
                )

                let updateDescription = try connection.prepare(
                    "UPDATE segment_description SET input_version = ? WHERE segment_id = ?"
                )
                try updateDescription.bind(.text(inputVersion), at: 1)
                try updateDescription.bind(.text(description.segmentID), at: 2)
                _ = try updateDescription.step()

                let updateRun = try connection.prepare(
                    """
                    UPDATE derivation_run
                    SET model_id = ?,
                        parameters_json = CASE
                            WHEN json_valid(parameters_json)
                            THEN json_set(parameters_json, '$.input_revision', ?)
                            ELSE json_object(
                                'prompt_version', ?,
                                'input_revision', ?
                            )
                        END
                    WHERE id = ? AND kind = 'description'
                    """
                )
                try updateRun.bind(.text(configuration.description.derivationID), at: 1)
                try updateRun.bind(.text(description.evidenceRevision), at: 2)
                try updateRun.bind(.text(description.promptVersion), at: 3)
                try updateRun.bind(.text(description.evidenceRevision), at: 4)
                try updateRun.bind(.text(description.runID), at: 5)
                _ = try updateRun.step()
            }

            // The embedding row is the atomic proof that the whole evidence
            // transaction completed. Restore any task the transitional build
            // incorrectly changed to pending/running/failed.
            let restoreIndexJobs = try connection.prepare(
                """
                UPDATE job
                SET status = 'succeeded', checkpoint_json = ?,
                    error_message = NULL, updated_at = ?
                WHERE kind = 'index_segment'
                  AND status <> 'succeeded'
                  AND segment_id IN (
                      SELECT segment_id
                      FROM segment_embedding
                      WHERE model_id = ? AND input_version = ?
                  )
                """
            )
            try restoreIndexJobs.bind(.text(migratedCheckpoint), at: 1)
            try restoreIndexJobs.bind(.real(now.timeIntervalSince1970), at: 2)
            try restoreIndexJobs.bind(.text(configuration.embedding.derivationID), at: 3)
            try restoreIndexJobs.bind(.text(currentInputVersion), at: 4)
            _ = try restoreIndexJobs.step()

            let restoreDescriptionJobs = try connection.prepare(
                """
                UPDATE job
                SET status = 'succeeded', checkpoint_json = ?,
                    error_message = NULL, updated_at = ?
                WHERE kind = 'describe_segment'
                  AND status <> 'succeeded'
                  AND segment_id IN (
                      SELECT d.segment_id
                      FROM segment_description d
                      JOIN derivation_run dr ON dr.id = d.derivation_run_id
                      JOIN segment_embedding e ON e.segment_id = d.segment_id
                      WHERE dr.model_id = ?
                        AND json_extract(
                            dr.parameters_json,
                            '$.input_revision'
                        ) = e.derivation_run_id
                  )
                """
            )
            try restoreDescriptionJobs.bind(.text(migratedCheckpoint), at: 1)
            try restoreDescriptionJobs.bind(.real(now.timeIntervalSince1970), at: 2)
            try restoreDescriptionJobs.bind(.text(configuration.description.derivationID), at: 3)
            _ = try restoreDescriptionJobs.step()

            try recordModelIdentityMigration(key: markerKey, value: currentInputVersion)
            return true
        }
    }

    /// ASR/alignment runs do not carry a segment ID, but every evidence commit
    /// creates them in the same asset/fingerprint/runtime/timestamp cohort as
    /// its embedding run. That cohort also covers silent segments whose run has
    /// no transcript row pointing back to it.
    private func migrateSiblingRunModelID(
        kind: String,
        legacyID: String,
        currentID: String,
        embeddingModelID: String,
        inputVersion: String
    ) throws {
        let statement = try connection.prepare(
            """
            UPDATE derivation_run
            SET model_id = ?
            WHERE kind = ? AND model_id = ?
              AND EXISTS (
                  SELECT 1
                  FROM derivation_run embedding_run
                  JOIN segment_embedding e
                    ON e.derivation_run_id = embedding_run.id
                  WHERE e.model_id = ? AND e.input_version = ?
                    AND embedding_run.kind = 'embedding'
                    AND embedding_run.asset_id = derivation_run.asset_id
                    AND embedding_run.source_fingerprint = derivation_run.source_fingerprint
                    AND coalesce(embedding_run.runtime_version, '') =
                        coalesce(derivation_run.runtime_version, '')
                    AND embedding_run.started_at = derivation_run.started_at
                    AND coalesce(embedding_run.completed_at, -1) =
                        coalesce(derivation_run.completed_at, -1)
              )
            """
        )
        try statement.bind(.text(currentID), at: 1)
        try statement.bind(.text(kind), at: 2)
        try statement.bind(.text(legacyID), at: 3)
        try statement.bind(.text(embeddingModelID), at: 4)
        try statement.bind(.text(inputVersion), at: 5)
        _ = try statement.step()
    }

    private func recordModelIdentityMigration(key: String, value: String) throws {
        let statement = try connection.prepare(
            "INSERT INTO application_metadata (key, value) VALUES (?, ?)"
        )
        try statement.bind(.text(key), at: 1)
        try statement.bind(.text(value), at: 2)
        _ = try statement.step()
    }
}
