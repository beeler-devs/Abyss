import Combine
import Foundation

/// Parses canvas.* tool results into CanvasCard models for inline display.
@MainActor
final class ConversationCanvasManager: ObservableObject {
    @Published private(set) var canvasCards: [CanvasCard] = []

    private let eventBus: EventBus
    private var pendingToolCalls: [String: Event.ToolCall] = [:]
    private var lastAssistantMessageID: UUID?

    init(eventBus: EventBus) {
        self.eventBus = eventBus
    }

    func updateLastAssistantMessageID(_ id: UUID) {
        lastAssistantMessageID = id
    }

    func handleEventStream(_ event: Event) {
        switch event.kind {
        case .toolCall(let toolCall):
            if toolCall.name.hasPrefix("canvas.") {
                pendingToolCalls[toolCall.callId] = toolCall
            }
        case .toolResult(let toolResult):
            guard let toolCall = pendingToolCalls.removeValue(forKey: toolResult.callId) else { return }
            handleCanvasResult(toolResult, for: toolCall)
        default:
            break
        }
    }

    func toggleExpanded(cardId: UUID) {
        guard let index = canvasCards.firstIndex(where: { $0.id == cardId }) else { return }
        canvasCards[index].isExpanded.toggle()
    }

    private func handleCanvasResult(_ result: Event.ToolResult, for toolCall: Event.ToolCall) {
        guard result.error == nil, let json = result.result else { return }
        guard let data = json.data(using: .utf8) else { return }

        switch toolCall.name {
        case "canvas.courses":
            parseCourses(data)
        case "canvas.assignments":
            parseAssignments(data)
        case "canvas.todo":
            parseTodo(data)
        case "canvas.grades":
            parseGrades(data)
        case "canvas.announcements":
            parseAnnouncements(data)
        default:
            break
        }
    }

    private func parseCourses(_ data: Data) {
        guard let items = try? JSONDecoder().decode([CanvasCoursePayload].self, from: data) else { return }
        for item in items {
            canvasCards.append(CanvasCard(variant: .course(CanvasCard.Course(
                courseId: String(item.id),
                name: item.name,
                courseCode: item.course_code,
                enrollmentTerm: item.enrollment_term_id.map { String($0) }
            )), anchorMessageID: lastAssistantMessageID, serverCardId: item.cardId))
        }
    }

    private func parseAssignments(_ data: Data) {
        guard let items = try? JSONDecoder().decode([CanvasAssignmentPayload].self, from: data) else { return }
        for item in items {
            canvasCards.append(CanvasCard(variant: .assignment(CanvasCard.Assignment(
                assignmentId: String(item.id),
                name: item.name,
                courseName: item.course_name,
                dueAt: item.due_at,
                pointsPossible: item.points_possible,
                submissionStatus: item.submission?.workflow_state,
                htmlUrl: item.html_url
            )), anchorMessageID: lastAssistantMessageID, serverCardId: item.cardId))
        }
    }

    private func parseTodo(_ data: Data) {
        guard let items = try? JSONDecoder().decode([CanvasTodoPayload].self, from: data) else { return }
        for item in items {
            canvasCards.append(CanvasCard(variant: .todo(CanvasCard.TodoItem(
                assignmentName: item.assignment?.name ?? "Unknown",
                courseName: item.context_name,
                dueAt: item.assignment?.due_at,
                type: item.type
            )), anchorMessageID: lastAssistantMessageID, serverCardId: item.cardId))
        }
    }

    private func parseGrades(_ data: Data) {
        guard let items = try? JSONDecoder().decode([CanvasGradePayload].self, from: data) else { return }
        for item in items {
            canvasCards.append(CanvasCard(variant: .grade(CanvasCard.Grade(
                courseName: item.course_name,
                currentScore: item.grades?.current_score,
                currentGrade: item.grades?.current_grade,
                finalScore: item.grades?.final_score,
                finalGrade: item.grades?.final_grade
            )), anchorMessageID: lastAssistantMessageID, serverCardId: item.cardId))
        }
    }

    private func parseAnnouncements(_ data: Data) {
        guard let items = try? JSONDecoder().decode([CanvasAnnouncementPayload].self, from: data) else { return }
        for item in items {
            canvasCards.append(CanvasCard(variant: .announcement(CanvasCard.Announcement(
                announcementId: String(item.id),
                title: item.title,
                message: item.message,
                postedAt: item.posted_at,
                authorName: item.author?.display_name
            )), anchorMessageID: lastAssistantMessageID, serverCardId: item.cardId))
        }
    }
}

// MARK: - Decodable helpers

private struct CanvasCoursePayload: Decodable {
    let id: Int
    let name: String
    let course_code: String?
    let enrollment_term_id: Int?
    let cardId: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, course_code, enrollment_term_id, cardId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        course_code = try container.decodeIfPresent(String.self, forKey: .course_code)
        enrollment_term_id = try container.decodeIfPresent(Int.self, forKey: .enrollment_term_id)
        cardId = try container.decodeIfPresent(String.self, forKey: .cardId)
    }
}

private struct CanvasAssignmentPayload: Decodable {
    let id: Int
    let name: String
    let course_name: String?
    let due_at: String?
    let points_possible: Double?
    let submission: SubmissionPayload?
    let html_url: String?
    let cardId: String?

    struct SubmissionPayload: Decodable {
        let workflow_state: String?
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, course_name, due_at, points_possible, submission, html_url, cardId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        course_name = try container.decodeIfPresent(String.self, forKey: .course_name)
        due_at = try container.decodeIfPresent(String.self, forKey: .due_at)
        points_possible = try container.decodeIfPresent(Double.self, forKey: .points_possible)
        submission = try container.decodeIfPresent(SubmissionPayload.self, forKey: .submission)
        html_url = try container.decodeIfPresent(String.self, forKey: .html_url)
        cardId = try container.decodeIfPresent(String.self, forKey: .cardId)
    }
}

private struct CanvasTodoPayload: Decodable {
    let type: String?
    let assignment: AssignmentPayload?
    let context_name: String?
    let cardId: String?

    struct AssignmentPayload: Decodable {
        let name: String?
        let due_at: String?
    }

    private enum CodingKeys: String, CodingKey {
        case type, assignment, context_name, cardId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        assignment = try container.decodeIfPresent(AssignmentPayload.self, forKey: .assignment)
        context_name = try container.decodeIfPresent(String.self, forKey: .context_name)
        cardId = try container.decodeIfPresent(String.self, forKey: .cardId)
    }
}

private struct CanvasGradePayload: Decodable {
    let course_name: String?
    let grades: GradesPayload?
    let cardId: String?

    struct GradesPayload: Decodable {
        let current_score: Double?
        let current_grade: String?
        let final_score: Double?
        let final_grade: String?
    }

    private enum CodingKeys: String, CodingKey {
        case course_name, grades, cardId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        course_name = try container.decodeIfPresent(String.self, forKey: .course_name)
        grades = try container.decodeIfPresent(GradesPayload.self, forKey: .grades)
        cardId = try container.decodeIfPresent(String.self, forKey: .cardId)
    }
}

private struct CanvasAnnouncementPayload: Decodable {
    let id: Int
    let title: String
    let message: String?
    let posted_at: String?
    let author: AuthorPayload?
    let cardId: String?

    struct AuthorPayload: Decodable {
        let display_name: String?
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, message, posted_at, author, cardId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        posted_at = try container.decodeIfPresent(String.self, forKey: .posted_at)
        author = try container.decodeIfPresent(AuthorPayload.self, forKey: .author)
        cardId = try container.decodeIfPresent(String.self, forKey: .cardId)
    }
}
