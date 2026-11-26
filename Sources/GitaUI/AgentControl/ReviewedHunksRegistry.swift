import Foundation
import GitaCore

@MainActor
final class ReviewedHunksRegistry {
    private let reviews = NSHashTable<ReviewedHunksPresenter>.weakObjects()
    private var stores: [URL: ReviewedHunksStore] = [:]

    func makeReviewedHunksPresenter(for repositoryRoot: URL) -> ReviewedHunksPresenter {
        let root = repositoryRoot.standardizedFileURL.resolvingSymlinksInPath()
        let store = stores[root] ?? ReviewedHunksStore(storageURL: ReviewedHunksStore.defaultStorageURL(for: root))
        stores[root] = store
        let presenter = ReviewedHunksPresenter(store: store)
        presenter.didWrite = { [weak self, weak presenter] path in
            guard let self, let presenter else { return }
            for peer in self.reviews.allObjects where peer !== presenter && peer.store === store {
                peer.refresh(filePath: path)
            }
        }
        reviews.add(presenter)
        return presenter
    }
}
