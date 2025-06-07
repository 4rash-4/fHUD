import Foundation

/// Very small placeholder graph storing concept relations.
final class ConceptGraph {
    private var relations: [String: [ConceptNode]] = [:]

    func addRelation(from concept: ConceptNode, to related: ConceptNode) {
        relations[concept.text, default: []].append(related)
    }

    func findRelated(_ concept: ConceptNode, threshold _: Float) -> [ConceptNode] {
        relations[concept.text] ?? []
    }
}
