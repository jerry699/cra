import CraCore
import Foundation
import Testing

/// The pinned GGUFs and where they come from: sizes, digests, tiers and the two equal sources.
struct ModelCatalogTests {
    @Test func recommendedFollowsMemory() {
        #expect(ModelCatalog.recommended(forMemory: 8 << 30).id == ModelCatalog.pointEightB.id)
        #expect(ModelCatalog.recommended(forMemory: 16 << 30).id == ModelCatalog.twoB.id)
    }

    @Test func entriesArePinnedAndSized() {
        for model in ModelCatalog.all {
            #expect(model.sha256.count == 64)
            #expect(model.sha256.allSatisfy { $0.isHexDigit })
            #expect(model.bytes > 400 << 20)
            #expect(model.fileName.hasSuffix(".gguf"))
            #expect(model.url(from: .modelScope)?.absoluteString.hasPrefix("https://") == true)
        }
        #expect(ModelCatalog.twoB.capabilities.contains(.tabs))
        #expect(!ModelCatalog.pointEightB.capabilities.contains(.tabs))
    }

    @Test func sourceDefaultsByRegion() {
        #expect(ModelSource.preferred(region: "CN") == .modelScope)
        #expect(ModelSource.preferred(region: "cn") == .modelScope)
        #expect(ModelSource.preferred(region: "US") == .huggingFace)
        #expect(ModelSource.preferred(region: nil) == .huggingFace)
    }

    @Test func everySourceServesThePinnedFile() {
        let model = ModelCatalog.twoB
        for source in ModelSource.allCases {
            let url = model.url(from: source)
            #expect(url?.scheme == "https")
            #expect(url?.absoluteString.contains(model.repository) == true)
            #expect(url?.absoluteString.hasSuffix(model.fileName) == true)
        }
        // The preferred source is tried first, the others still follow.
        #expect(model.sources(preferred: .modelScope).first == .modelScope)
        #expect(Set(model.sources(preferred: .huggingFace)) == Set(ModelSource.allCases))
    }

    @Test func downloadNeedsRoomForTheCopy() {
        #expect(!ModelCatalog.fits(ModelCatalog.twoB, freeBytes: ModelCatalog.twoB.bytes))
        #expect(ModelCatalog.fits(ModelCatalog.twoB, freeBytes: ModelCatalog.twoB.bytes * 2))
    }
}
