import Foundation

/// Simple crystallizer that groups related concepts.
final class ThoughtCrystallizer {
    private let conceptGraph: ConceptGraph
    private var crystallizationThreshold: Float = 0.7

    init(graph: ConceptGraph) {
        self.conceptGraph = graph
    }

    func processNewConcept(_ concept: ConceptNode) {
        let related = conceptGraph.findRelated(concept, threshold: 0.5)
        if related.count >= 3 && calculateCoherence(related) > crystallizationThreshold {
            crystallizeMoment(concept, related)
        }
    }

    private func calculateCoherence(_ nodes: [ConceptNode]) -> Float {
        // Placeholder coherence calculation
        return Float(nodes.count) / 5.0
    }

    private func crystallizeMoment(_ primary: ConceptNode, _ related: [ConceptNode]) {
        // TODO: handle visualization and storage
        print("✨ Crystallized thought around \(primary.text)")
    }
}
