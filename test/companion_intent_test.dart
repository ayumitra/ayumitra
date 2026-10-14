import 'package:ayumitra/domain/companion_intent.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('companion request routing', () {
    test('health report composition is a supported assistant request', () {
      for (final request in [
        'Craft a health report from my conversations',
        'Please generate a medical summary',
        'Can you write a clinical report?',
        'Summarise my health history',
        'Create a report about my health',
        'Could you please craft a health report?',
        'I need a medical summary',
        "I'd like a health report",
        'Can I have a clinical report?',
      ]) {
        expect(isAssistantRequest(request), isTrue, reason: request);
        expect(isHealthReportRequest(request), isTrue, reason: request);
        expect(isDraftRequest(request), isTrue, reason: request);
        expect(isInformationRequest(request), isFalse, reason: request);
      }
    });

    test('questions about reports do not compose a document', () {
      for (final request in [
        'What is a health report?',
        'What does a medical summary contain?',
        'Explain how to write a health report',
        'How can I create a medical summary?',
        'Tell me how to draft a second-opinion brief',
        'Could you explain how to write a health report?',
        'I want you to explain how to craft a clinical report',
        'What should I write in a health report?',
      ]) {
        expect(isHealthReportRequest(request), isFalse, reason: request);
        expect(isDraftRequest(request), isFalse, reason: request);
        expect(isInformationRequest(request), isTrue, reason: request);
      }
    });

    test('polite drafting instructions remain composition requests', () {
      for (final request in [
        'Write a letter for my clinician',
        'Help me draft a second-opinion brief',
        'Can you help me write a handover note?',
        'I would like you to draft a letter',
        'I need you to create a summary',
        'Please summarize what I have told you',
      ]) {
        expect(isAssistantRequest(request), isTrue, reason: request);
        expect(isDraftRequest(request), isTrue, reason: request);
      }
    });

    test('assistant imperatives are not patient observations', () {
      for (final request in [
        'Write that my hemoglobin was 13',
        'Compile the readings from March 2026',
        'Please find my reports',
        'Show my blood pressure history',
        'Explain this result',
        'Can you compare these values?',
        'I would like you to draft a letter',
        'I need you to create a summary',
      ]) {
        expect(isAssistantRequest(request), isTrue, reason: request);
      }
      for (final observation in [
        'My hemoglobin was 13 yesterday',
        'I measured my temperature at 37 today',
        'My blood pressure is 120/80',
        'Remember my temperature was 37 today',
        'Please record my blood pressure was 120/80 today',
        'Save that my oxygen saturation was 98%',
        'Log pulse 72 bpm',
        'I have a report from March 14, 2026',
        'The doctor said I can take this medication',
      ]) {
        expect(isAssistantRequest(observation), isFalse, reason: observation);
      }
    });

    test('general medical explainers can use public information', () {
      for (final request in [
        'What is blood pressure?',
        'Explain oxygen saturation',
        'Why does temperature change during the day?',
        'Can paracetamol reduce a fever?',
        'Tell me about asthma',
        'What does my medication usually do?',
        'Should I measure my temperature again?',
      ]) {
        expect(isInformationRequest(request), isTrue, reason: request);
      }
    });

    test('private conversational recall is not a public explanation', () {
      for (final request in [
        'What did I note about zephyrin?',
        'What did I tell you about zephyrin?',
        'What have I said about zephyrin?',
        'What have I reported?',
        'What had I recorded yesterday?',
        'Recall my earlier notes about zephyrin',
        'Please recall what I told you',
        'Remind me what I said',
        'Do you remember what I told you?',
        'Show my saved conversation notes',
        'Summarize my zephyrin note',
        'Can you summarize my earlier notes?',
      ]) {
        expect(isAssistantRequest(request), isTrue, reason: request);
        expect(isInformationRequest(request), isFalse, reason: request);
      }
      for (final request in [
        'What did researchers find about oxygen saturation?',
        'What have clinical trials reported about this medicine?',
        'Explain how researchers record blood pressure',
      ]) {
        expect(isInformationRequest(request), isTrue, reason: request);
      }
    });

    test('summarizing saved notes stays in the private recall answer path', () {
      for (final request in [
        'Summarize my zephyrin note',
        'Please summarize my previous conversation',
        'Can you summarize my earlier notes?',
      ]) {
        expect(isAssistantRequest(request), isTrue, reason: request);
        expect(isDraftRequest(request), isFalse, reason: request);
        expect(isInformationRequest(request), isFalse, reason: request);
      }
      expect(isDraftRequest('Summarize my health history'), isTrue);
      expect(isHealthReportRequest('Summarize my health history'), isTrue);
    });

    test('personal recorded values are routed to private history', () {
      for (final request in [
        'What was my hemoglobin on March 14, 2026?',
        'What is my latest blood pressure?',
        'When did my temperature last rise?',
        'Show my saved reports from 2026',
        'Find my uploaded files',
        'What were her recorded readings?',
        'What is my blood pressure on 2026-03-14?',
      ]) {
        expect(isAssistantRequest(request), isTrue, reason: request);
        expect(isInformationRequest(request), isFalse, reason: request);
      }
    });
  });
}
