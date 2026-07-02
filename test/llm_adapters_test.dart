import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:pin/agent/llm_adapters.dart';

void main() {
  final tools = [
    {
      'type': 'function',
      'function': {
        'name': 'get_weather',
        'description': 'w',
        'parameters': {
          'type': 'object',
          'properties': {
            'city': {'type': 'string'}
          },
          'additionalProperties': false,
        },
      }
    }
  ];
  // A tool-use round: system, user, assistant→call, tool result.
  final messages = [
    {'role': 'system', 'content': 'be nice'},
    {'role': 'user', 'content': 'weather?'},
    {
      'role': 'assistant',
      'tool_calls': [
        {
          'id': 'c1',
          'type': 'function',
          'function': {'name': 'get_weather', 'arguments': '{"city":"BKK"}'}
        }
      ]
    },
    {'role': 'tool', 'tool_call_id': 'c1', 'content': '31C'},
  ];

  group('gemini', () {
    test('request: system→instruction, calls→functionCall, result→functionResponse', () {
      final b = openAiToGemini(messages, tools);
      expect(b['systemInstruction']['parts'][0]['text'], 'be nice');
      final contents = b['contents'] as List;
      // user, model(functionCall), user(functionResponse)
      expect(contents[1]['parts'][0]['functionCall']['name'], 'get_weather');
      expect(contents[1]['parts'][0]['functionCall']['args']['city'], 'BKK');
      final fr = contents[2]['parts'][0]['functionResponse'];
      expect(fr['name'], 'get_weather'); // resolved from id→name
      // schema cleaned of additionalProperties
      final decl = b['tools'][0]['functionDeclarations'][0];
      expect(decl['parameters'].containsKey('additionalProperties'), isFalse);
    });

    test('response: functionCall + text → OpenAI choices', () {
      final resp = geminiToOpenAi({
        'candidates': [
          {
            'content': {
              'parts': [
                {'text': 'ok'},
                {
                  'functionCall': {'name': 'get_weather', 'args': {'city': 'BKK'}}
                }
              ]
            }
          }
        ],
        'usageMetadata': {'promptTokenCount': 5, 'candidatesTokenCount': 3},
      });
      final msg = resp['choices'][0]['message'];
      expect(msg['content'], 'ok');
      expect(msg['tool_calls'][0]['function']['name'], 'get_weather');
      expect(jsonDecode(msg['tool_calls'][0]['function']['arguments'])['city'],
          'BKK');
      expect(resp['usage']['prompt_tokens'], 5);
    });
  });

  group('claude', () {
    test('request: system string, tool_use + tool_result blocks', () {
      final b = openAiToClaude(messages, tools);
      expect(b['system'], 'be nice');
      final msgs = b['messages'] as List;
      expect(msgs[1]['content'][0]['type'], 'tool_use');
      expect(msgs[1]['content'][0]['name'], 'get_weather');
      expect(msgs[2]['content'][0]['type'], 'tool_result');
      expect(msgs[2]['content'][0]['tool_use_id'], 'c1');
      expect(b['tools'][0]['input_schema']['properties']['city']['type'],
          'string');
    });

    test('response: tool_use block → OpenAI tool_calls', () {
      final resp = claudeToOpenAi({
        'content': [
          {'type': 'text', 'text': 'sure'},
          {
            'type': 'tool_use',
            'id': 'tu1',
            'name': 'get_weather',
            'input': {'city': 'BKK'}
          }
        ],
        'usage': {'input_tokens': 7, 'output_tokens': 2},
      });
      final msg = resp['choices'][0]['message'];
      expect(msg['content'], 'sure');
      expect(msg['tool_calls'][0]['id'], 'tu1');
      expect(jsonDecode(msg['tool_calls'][0]['function']['arguments'])['city'],
          'BKK');
      expect(resp['usage']['completion_tokens'], 2);
    });
  });
}
