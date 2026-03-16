import Foundation

struct CanvasCard: Identifiable, Equatable, Sendable {
    let id: UUID
    let variant: Variant
    var isExpanded: Bool
    var anchorMessageID: UUID?
    var serverCardId: String?

    enum Variant: Equatable, Sendable {
        case course(Course)
        case assignment(Assignment)
        case todo(TodoItem)
        case grade(Grade)
        case announcement(Announcement)
    }

    struct Course: Equatable, Sendable {
        let courseId: String
        let name: String
        let courseCode: String?
        let enrollmentTerm: String?
    }

    struct Assignment: Equatable, Sendable {
        let assignmentId: String
        let name: String
        let courseName: String?
        let dueAt: String?
        let pointsPossible: Double?
        let submissionStatus: String?
        let htmlUrl: String?
    }

    struct TodoItem: Equatable, Sendable {
        let assignmentName: String
        let courseName: String?
        let dueAt: String?
        let type: String?
    }

    struct Grade: Equatable, Sendable {
        let courseName: String?
        let currentScore: Double?
        let currentGrade: String?
        let finalScore: Double?
        let finalGrade: String?
    }

    struct Announcement: Equatable, Sendable {
        let announcementId: String
        let title: String
        let message: String?
        let postedAt: String?
        let authorName: String?
    }

    init(
        id: UUID = UUID(),
        variant: Variant,
        isExpanded: Bool = false,
        anchorMessageID: UUID? = nil,
        serverCardId: String? = nil
    ) {
        self.id = id
        self.variant = variant
        self.isExpanded = isExpanded
        self.anchorMessageID = anchorMessageID
        self.serverCardId = serverCardId
    }
}
