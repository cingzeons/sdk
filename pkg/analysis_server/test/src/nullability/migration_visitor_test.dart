// Copyright (c) 2019, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/src/nullability/conditional_discard.dart';
import 'package:analysis_server/src/nullability/constraint_gatherer.dart';
import 'package:analysis_server/src/nullability/constraint_variable_gatherer.dart';
import 'package:analysis_server/src/nullability/decorated_type.dart';
import 'package:analysis_server/src/nullability/expression_checks.dart';
import 'package:analysis_server/src/nullability/nullability_node.dart';
import 'package:analysis_server/src/nullability/transitional_api.dart';
import 'package:analysis_server/src/nullability/unit_propagation.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/src/generated/resolver.dart';
import 'package:analyzer/src/generated/source.dart';
import 'package:analyzer/src/test_utilities/find_node.dart';
import 'package:test/test.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import '../../abstract_single_unit.dart';

main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(ConstraintGathererTest);
    defineReflectiveTests(ConstraintVariableGathererTest);
  });
}

@reflectiveTest
class ConstraintGathererTest extends ConstraintsTestBase {
  @override
  final _Constraints constraints = _Constraints();

  void assertConditional(
      NullabilityNode node, NullabilityNode left, NullabilityNode right) {
    var conditionalNode = node as NullabilityNodeForLUB;
    expect(conditionalNode.left, same(left));
    expect(conditionalNode.right, same(right));
    if (left.isNeverNullable) {
      if (right.isNeverNullable) {
        expect(conditionalNode.isNeverNullable, true);
      } else {
        expect(conditionalNode.nullable, same(right.nullable));
      }
    } else {
      if (right.isNeverNullable) {
        expect(conditionalNode.nullable, same(left.nullable));
      } else {
        assertConstraint([left.nullable], conditionalNode.nullable);
        assertConstraint([right.nullable], conditionalNode.nullable);
      }
    }
  }

  /// Checks that a constraint was recorded with a left hand side of
  /// [conditions] and a right hand side of [consequence].
  void assertConstraint(
      Iterable<ConstraintVariable> conditions, ConstraintVariable consequence) {
    expect(constraints._clauses,
        contains(_Clause(conditions.toSet(), consequence)));
  }

  /// Checks that no constraint was recorded with a right hand side of
  /// [consequence].
  void assertNoConstraints(ConstraintVariable consequence) {
    expect(
        constraints._clauses,
        isNot(contains(
            predicate((_Clause clause) => clause.consequence == consequence))));
  }

  void assertNonNullIntent(NullabilityNode node, bool expected) {
    if (expected) {
      assertConstraint([], node.nonNullIntent);
    } else {
      assertNoConstraints(node.nonNullIntent);
    }
  }

  /// Verifies that a null check will occur under the proper circumstances.
  ///
  /// [expressionChecks] is the object tracking whether or not a null check is
  /// needed.  [valueNode] is the node representing the possibly-nullable value
  /// that is the source of the assignment or use.  [contextNode] is the node
  /// representing the possibly-nullable value that is the destination of the
  /// assignment (if the value is being assigned), or `null` if the value is
  /// being used in a circumstance where `null` is not permitted.  [guards] is
  /// a list of nullability nodes for which there are enclosing if statements
  /// checking that the corresponding values are non-null.
  void assertNullCheck(
      ExpressionChecks expressionChecks, NullabilityNode valueNode,
      {NullabilityNode contextNode, List<NullabilityNode> guards = const []}) {
    expect(expressionChecks.valueNode, same(valueNode));
    if (contextNode == null) {
      expect(expressionChecks.contextNode, same(NullabilityNode.never));
    } else {
      expect(expressionChecks.contextNode, same(contextNode));
    }
    expect(expressionChecks.guards, guards);
  }

  /// Gets the [ExpressionChecks] associated with the expression whose text
  /// representation is [text], or `null` if the expression has no
  /// [ExpressionChecks] associated with it.
  ExpressionChecks checkExpression(String text) {
    return _variables.checkExpression(findNode.expression(text));
  }

  /// Gets the [DecoratedType] associated with the expression whose text
  /// representation is [text], or `null` if the expression has no
  /// [DecoratedType] associated with it.
  DecoratedType decoratedExpressionType(String text) {
    return _variables.decoratedExpressionType(findNode.expression(text));
  }

  test_always() async {
    await analyze('');

    // No clause is needed for `always`; it is assigned the value `true` before
    // solving begins.
    assertNoConstraints(ConstraintVariable.always);
    assert(ConstraintVariable.always.value, isTrue);
  }

  test_assert_demonstrates_non_null_intent() async {
    await analyze('''
void f(int i) {
  assert(i != null);
}
''');

    assertNonNullIntent(decoratedTypeAnnotation('int i').node, true);
  }

  test_binaryExpression_add_left_check() async {
    await analyze('''
int f(int i, int j) => i + j;
''');

    assertNullCheck(
        checkExpression('i +'), decoratedTypeAnnotation('int i').node);
  }

  test_binaryExpression_add_left_check_custom() async {
    await analyze('''
class Int {
  Int operator+(Int other) => this;
}
Int f(Int i, Int j) => i + j;
''');

    assertNullCheck(
        checkExpression('i +'), decoratedTypeAnnotation('Int i').node);
  }

  test_binaryExpression_add_result_custom() async {
    await analyze('''
class Int {
  Int operator+(Int other) => this;
}
Int f(Int i, Int j) => (i + j);
''');

    assertNullCheck(checkExpression('(i + j)'),
        decoratedTypeAnnotation('Int operator+').node,
        contextNode: decoratedTypeAnnotation('Int f').node);
  }

  test_binaryExpression_add_result_not_null() async {
    await analyze('''
int f(int i, int j) => i + j;
''');

    assertNoConstraints(decoratedTypeAnnotation('int f').node.nullable);
  }

  test_binaryExpression_add_right_check() async {
    await analyze('''
int f(int i, int j) => i + j;
''');

    assertNullCheck(
        checkExpression('j;'), decoratedTypeAnnotation('int j').node);
  }

  test_binaryExpression_add_right_check_custom() async {
    await analyze('''
class Int {
  Int operator+(Int other) => this;
}
Int f(Int i, Int j) => i + j/*check*/;
''');

    assertNullCheck(
        checkExpression('j/*check*/'), decoratedTypeAnnotation('Int j').node,
        contextNode: decoratedTypeAnnotation('Int other').node);
  }

  test_binaryExpression_equal() async {
    await analyze('''
bool f(int i, int j) => i == j;
''');

    assertNoConstraints(decoratedTypeAnnotation('bool f').node.nullable);
  }

  test_boolLiteral() async {
    await analyze('''
bool f() {
  return true;
}
''');
    assertNoConstraints(decoratedTypeAnnotation('bool').node.nullable);
  }

  test_conditionalExpression_condition_check() async {
    await analyze('''
int f(bool b, int i, int j) {
  return (b ? i : j);
}
''');

    var nullable_b = decoratedTypeAnnotation('bool b').node;
    var check_b = checkExpression('b ?');
    assertNullCheck(check_b, nullable_b);
  }

  test_conditionalExpression_general() async {
    await analyze('''
int f(bool b, int i, int j) {
  return (b ? i : j);
}
''');

    var nullable_i = decoratedTypeAnnotation('int i').node;
    var nullable_j = decoratedTypeAnnotation('int j').node;
    var nullable_conditional = decoratedExpressionType('(b ?').node;
    assertConditional(nullable_conditional, nullable_i, nullable_j);
    var nullable_return = decoratedTypeAnnotation('int f').node;
    assertNullCheck(checkExpression('(b ? i : j)'), nullable_conditional,
        contextNode: nullable_return);
  }

  test_conditionalExpression_left_non_null() async {
    await analyze('''
int f(bool b, int i) {
  return (b ? (throw i) : i);
}
''');

    var nullable_i = decoratedTypeAnnotation('int i').node;
    var nullable_conditional =
        decoratedExpressionType('(b ?').node as NullabilityNodeForLUB;
    var nullable_throw = nullable_conditional.left;
    expect(nullable_throw.isNeverNullable, true);
    assertConditional(nullable_conditional, nullable_throw, nullable_i);
  }

  test_conditionalExpression_left_null() async {
    await analyze('''
int f(bool b, int i) {
  return (b ? null : i);
}
''');

    var nullable_conditional = decoratedExpressionType('(b ?').node;
    expect(nullable_conditional.isAlwaysNullable, true);
  }

  test_conditionalExpression_right_non_null() async {
    await analyze('''
int f(bool b, int i) {
  return (b ? i : (throw i));
}
''');

    var nullable_i = decoratedTypeAnnotation('int i').node;
    var nullable_conditional =
        decoratedExpressionType('(b ?').node as NullabilityNodeForLUB;
    var nullable_throw = nullable_conditional.right;
    expect(nullable_throw.isNeverNullable, true);
    assertConditional(nullable_conditional, nullable_i, nullable_throw);
  }

  test_conditionalExpression_right_null() async {
    await analyze('''
int f(bool b, int i) {
  return (b ? i : null);
}
''');

    var nullable_conditional = decoratedExpressionType('(b ?').node;
    expect(nullable_conditional.isAlwaysNullable, true);
  }

  test_functionDeclaration_expression_body() async {
    await analyze('''
int/*1*/ f(int/*2*/ i) => i/*3*/;
''');

    assertNullCheck(
        checkExpression('i/*3*/'), decoratedTypeAnnotation('int/*2*/').node,
        contextNode: decoratedTypeAnnotation('int/*1*/').node);
  }

  test_functionDeclaration_parameter_named_default_notNull() async {
    await analyze('''
void f({int i = 1}) {}
''');

    assertNoConstraints(decoratedTypeAnnotation('int').node.nullable);
  }

  test_functionDeclaration_parameter_named_default_null() async {
    await analyze('''
void f({int i = null}) {}
''');

    assertConstraint([ConstraintVariable.always],
        decoratedTypeAnnotation('int').node.nullable);
  }

  test_functionDeclaration_parameter_named_no_default_assume_nullable() async {
    await analyze('''
void f({int i}) {}
''',
        assumptions: NullabilityMigrationAssumptions(
            namedNoDefaultParameterHeuristic:
                NamedNoDefaultParameterHeuristic.assumeNullable));

    assertConstraint([ConstraintVariable.always],
        decoratedTypeAnnotation('int').node.nullable);
  }

  test_functionDeclaration_parameter_named_no_default_assume_required() async {
    await analyze('''
void f({int i}) {}
''',
        assumptions: NullabilityMigrationAssumptions(
            namedNoDefaultParameterHeuristic:
                NamedNoDefaultParameterHeuristic.assumeRequired));

    assertNoConstraints(decoratedTypeAnnotation('int').node.nullable);
  }

  test_functionDeclaration_parameter_named_no_default_required_assume_nullable() async {
    addMetaPackage();
    await analyze('''
import 'package:meta/meta.dart';
void f({@required int i}) {}
''',
        assumptions: NullabilityMigrationAssumptions(
            namedNoDefaultParameterHeuristic:
                NamedNoDefaultParameterHeuristic.assumeNullable));

    assertNoConstraints(decoratedTypeAnnotation('int').node.nullable);
  }

  test_functionDeclaration_parameter_named_no_default_required_assume_required() async {
    addMetaPackage();
    await analyze('''
import 'package:meta/meta.dart';
void f({@required int i}) {}
''',
        assumptions: NullabilityMigrationAssumptions(
            namedNoDefaultParameterHeuristic:
                NamedNoDefaultParameterHeuristic.assumeRequired));

    assertNoConstraints(decoratedTypeAnnotation('int').node.nullable);
  }

  test_functionDeclaration_parameter_positionalOptional_default_notNull() async {
    await analyze('''
void f([int i = 1]) {}
''');

    assertNoConstraints(decoratedTypeAnnotation('int').node.nullable);
  }

  test_functionDeclaration_parameter_positionalOptional_default_null() async {
    await analyze('''
void f([int i = null]) {}
''');

    assertConstraint([ConstraintVariable.always],
        decoratedTypeAnnotation('int').node.nullable);
  }

  test_functionDeclaration_parameter_positionalOptional_no_default() async {
    await analyze('''
void f([int i]) {}
''');

    assertConstraint([ConstraintVariable.always],
        decoratedTypeAnnotation('int').node.nullable);
  }

  test_functionDeclaration_parameter_positionalOptional_no_default_assume_required() async {
    // Note: the `assumeRequired` behavior shouldn't affect the behavior here
    // because it only affects named parameters.
    await analyze('''
void f([int i]) {}
''',
        assumptions: NullabilityMigrationAssumptions(
            namedNoDefaultParameterHeuristic:
                NamedNoDefaultParameterHeuristic.assumeRequired));

    assertConstraint([ConstraintVariable.always],
        decoratedTypeAnnotation('int').node.nullable);
  }

  test_functionDeclaration_resets_unconditional_control_flow() async {
    await analyze('''
void f(bool b, int i, int j) {
  assert(i != null);
  if (b) return;
  assert(j != null);
}
void g(int k) {
  assert(k != null);
}
''');
    assertNonNullIntent(decoratedTypeAnnotation('int i').node, true);
    assertNonNullIntent(decoratedTypeAnnotation('int j').node, false);
    assertNonNullIntent(decoratedTypeAnnotation('int k').node, true);
  }

  test_functionInvocation_parameter_fromLocalParameter() async {
    await analyze('''
void f(int/*1*/ i) {}
void test(int/*2*/ i) {
  f(i/*3*/);
}
''');

    var int_1 = decoratedTypeAnnotation('int/*1*/');
    var int_2 = decoratedTypeAnnotation('int/*2*/');
    var i_3 = checkExpression('i/*3*/');
    assertNullCheck(i_3, int_2.node, contextNode: int_1.node);
    assertConstraint([int_1.node.nonNullIntent], int_2.node.nonNullIntent);
  }

  test_functionInvocation_parameter_named() async {
    await analyze('''
void f({int i: 0}) {}
void g(int j) {
  f(i: j/*check*/);
}
''');
    var nullable_i = decoratedTypeAnnotation('int i').node;
    var nullable_j = decoratedTypeAnnotation('int j').node;
    assertNullCheck(checkExpression('j/*check*/'), nullable_j,
        contextNode: nullable_i);
  }

  test_functionInvocation_parameter_named_missing() async {
    await analyze('''
void f({int i}) {}
void g() {
  f();
}
''');
    var optional_i = possiblyOptionalParameter('int i');
    assertConstraint([], optional_i.nullable);
  }

  test_functionInvocation_parameter_named_missing_required() async {
    addMetaPackage();
    verifyNoTestUnitErrors = false;
    await analyze('''
import 'package:meta/meta.dart';
void f({@required int i}) {}
void g() {
  f();
}
''');
    // The call at `f()` is presumed to be in error; no constraint is recorded.
    var optional_i = possiblyOptionalParameter('int i');
    expect(optional_i, isNull);
    var nullable_i = decoratedTypeAnnotation('int i').node.nullable;
    assertNoConstraints(nullable_i);
  }

  test_functionInvocation_parameter_null() async {
    await analyze('''
void f(int i) {}
void test() {
  f(null);
}
''');

    assertNullCheck(checkExpression('null'), NullabilityNode.always,
        contextNode: decoratedTypeAnnotation('int').node);
  }

  test_functionInvocation_return() async {
    await analyze('''
int/*1*/ f() => 0;
int/*2*/ g() {
  return (f());
}
''');

    assertNullCheck(
        checkExpression('(f())'), decoratedTypeAnnotation('int/*1*/').node,
        contextNode: decoratedTypeAnnotation('int/*2*/').node);
  }

  test_if_condition() async {
    await analyze('''
void f(bool b) {
  if (b) {}
}
''');

    assertNullCheck(
        checkExpression('b) {}'), decoratedTypeAnnotation('bool b').node);
  }

  test_if_conditional_control_flow_after() async {
    // Asserts after ifs don't demonstrate non-null intent.
    // TODO(paulberry): if both branches complete normally, they should.
    await analyze('''
void f(bool b, int i) {
  if (b) return;
  assert(i != null);
}
''');

    assertNonNullIntent(decoratedTypeAnnotation('int i').node, false);
  }

  test_if_conditional_control_flow_within() async {
    // Asserts inside ifs don't demonstrate non-null intent.
    await analyze('''
void f(bool b, int i) {
  if (b) {
    assert(i != null);
  } else {
    assert(i != null);
  }
}
''');

    assertNonNullIntent(decoratedTypeAnnotation('int i').node, false);
  }

  test_if_guard_equals_null() async {
    await analyze('''
int f(int i, int j, int k) {
  if (i == null) {
    return j/*check*/;
  } else {
    return k/*check*/;
  }
}
''');
    var nullable_i = decoratedTypeAnnotation('int i').node;
    var nullable_j = decoratedTypeAnnotation('int j').node;
    var nullable_k = decoratedTypeAnnotation('int k').node;
    var nullable_return = decoratedTypeAnnotation('int f').node;
    assertNullCheck(checkExpression('j/*check*/'), nullable_j,
        contextNode: nullable_return, guards: [nullable_i]);
    assertNullCheck(checkExpression('k/*check*/'), nullable_k,
        contextNode: nullable_return);
    var discard = statementDiscard('if (i == null)');
    expect(discard.trueGuard, same(nullable_i));
    expect(discard.falseGuard, null);
    expect(discard.pureCondition, true);
  }

  test_if_simple() async {
    await analyze('''
int f(bool b, int i, int j) {
  if (b) {
    return i/*check*/;
  } else {
    return j/*check*/;
  }
}
''');

    var nullable_i = decoratedTypeAnnotation('int i').node;
    var nullable_j = decoratedTypeAnnotation('int j').node;
    var nullable_return = decoratedTypeAnnotation('int f').node;
    assertNullCheck(checkExpression('i/*check*/'), nullable_i,
        contextNode: nullable_return);
    assertNullCheck(checkExpression('j/*check*/'), nullable_j,
        contextNode: nullable_return);
  }

  test_if_without_else() async {
    await analyze('''
int f(bool b, int i) {
  if (b) {
    return i/*check*/;
  }
  return 0;
}
''');

    var nullable_i = decoratedTypeAnnotation('int i').node;
    var nullable_return = decoratedTypeAnnotation('int f').node;
    assertNullCheck(checkExpression('i/*check*/'), nullable_i,
        contextNode: nullable_return);
  }

  test_intLiteral() async {
    await analyze('''
int f() {
  return 0;
}
''');
    assertNoConstraints(decoratedTypeAnnotation('int').node.nullable);
  }

  test_methodDeclaration_resets_unconditional_control_flow() async {
    await analyze('''
class C {
  void f(bool b, int i, int j) {
    assert(i != null);
    if (b) return;
    assert(j != null);
  }
  void g(int k) {
    assert(k != null);
  }
}
''');
    assertNonNullIntent(decoratedTypeAnnotation('int i').node, true);
    assertNonNullIntent(decoratedTypeAnnotation('int j').node, false);
    assertNonNullIntent(decoratedTypeAnnotation('int k').node, true);
  }

  test_methodInvocation_parameter_contravariant() async {
    await analyze('''
class C<T> {
  void f(T t) {}
}
void g(C<int> c, int i) {
  c.f(i/*check*/);
}
''');

    var nullable_i = decoratedTypeAnnotation('int i').node;
    var nullable_c_t = decoratedTypeAnnotation('C<int>').typeArguments[0].node;
    var nullable_t = decoratedTypeAnnotation('T t').node;
    var check_i = checkExpression('i/*check*/');
    var nullable_c_t_or_nullable_t =
        check_i.contextNode as NullabilityNodeForSubstitution;
    expect(nullable_c_t_or_nullable_t.innerNode, same(nullable_c_t));
    expect(nullable_c_t_or_nullable_t.outerNode, same(nullable_t));
    assertNullCheck(check_i, nullable_i,
        contextNode: nullable_c_t_or_nullable_t);
  }

  test_methodInvocation_parameter_generic() async {
    await analyze('''
class C<T> {}
void f(C<int/*1*/>/*2*/ c) {}
void g(C<int/*3*/>/*4*/ c) {
  f(c/*check*/);
}
''');

    assertConstraint([decoratedTypeAnnotation('int/*3*/').node.nullable],
        decoratedTypeAnnotation('int/*1*/').node.nullable);
    assertNullCheck(checkExpression('c/*check*/'),
        decoratedTypeAnnotation('C<int/*3*/>/*4*/').node,
        contextNode: decoratedTypeAnnotation('C<int/*1*/>/*2*/').node);
  }

  test_methodInvocation_parameter_named() async {
    await analyze('''
class C {
  void f({int i: 0}) {}
}
void g(C c, int j) {
  c.f(i: j/*check*/);
}
''');
    var nullable_i = decoratedTypeAnnotation('int i').node;
    var nullable_j = decoratedTypeAnnotation('int j').node;
    assertNullCheck(checkExpression('j/*check*/'), nullable_j,
        contextNode: nullable_i);
  }

  test_methodInvocation_target_check() async {
    await analyze('''
class C {
  void m() {}
}
void test(C c) {
  c.m();
}
''');

    assertNullCheck(
        checkExpression('c.m'), decoratedTypeAnnotation('C c').node);
  }

  test_methodInvocation_target_demonstrates_non_null_intent() async {
    await analyze('''
class C {
  void m() {}
}
void test(C c) {
  c.m();
}
''');

    assertNonNullIntent(decoratedTypeAnnotation('C c').node, true);
  }

  test_parenthesizedExpression() async {
    await analyze('''
int f() {
  return (null);
}
''');

    assertNullCheck(checkExpression('(null)'), NullabilityNode.always,
        contextNode: decoratedTypeAnnotation('int').node);
  }

  test_return_implicit_null() async {
    verifyNoTestUnitErrors = false;
    await analyze('''
int f() {
  return;
}
''');

    assertConstraint([ConstraintVariable.always],
        decoratedTypeAnnotation('int').node.nullable);
  }

  test_return_null() async {
    await analyze('''
int f() {
  return null;
}
''');

    assertNullCheck(checkExpression('null'), NullabilityNode.always,
        contextNode: decoratedTypeAnnotation('int').node);
  }

  test_stringLiteral() async {
    // TODO(paulberry): also test string interpolations
    await analyze('''
String f() {
  return 'x';
}
''');
    assertNoConstraints(decoratedTypeAnnotation('String').node.nullable);
  }

  test_thisExpression() async {
    await analyze('''
class C {
  C f() => this;
}
''');

    assertNoConstraints(decoratedTypeAnnotation('C f').node.nullable);
  }

  test_throwExpression() async {
    await analyze('''
int f() {
  return throw null;
}
''');
    assertNoConstraints(decoratedTypeAnnotation('int').node.nullable);
  }

  test_typeName() async {
    await analyze('''
Type f() {
  return int;
}
''');
    assertNoConstraints(decoratedTypeAnnotation('Type').node.nullable);
  }
}

abstract class ConstraintsTestBase extends MigrationVisitorTestBase {
  Constraints get constraints;

  /// Analyzes the given source code, producing constraint variables and
  /// constraints for it.
  @override
  Future<CompilationUnit> analyze(String code,
      {NullabilityMigrationAssumptions assumptions:
          const NullabilityMigrationAssumptions()}) async {
    var unit = await super.analyze(code);
    unit.accept(ConstraintGatherer(
        typeProvider, _variables, constraints, testSource, false, assumptions));
    return unit;
  }
}

@reflectiveTest
class ConstraintVariableGathererTest extends MigrationVisitorTestBase {
  /// Gets the [DecoratedType] associated with the function declaration whose
  /// name matches [search].
  DecoratedType decoratedFunctionType(String search) =>
      _variables.decoratedElementType(
          findNode.functionDeclaration(search).declaredElement);

  @failingTest
  test_interfaceType_nullable() async {
    // The tests are now being run without enabling nnbd, which causes the '?'
    // to be reported as an error.
    await analyze('''
void f(int? x) {}
''');
    var decoratedType = decoratedTypeAnnotation('int?');
    expect(decoratedFunctionType('f').positionalParameters[0],
        same(decoratedType));
    expect(decoratedType.node.nullable, same(ConstraintVariable.always));
  }

  test_interfaceType_typeParameter() async {
    await analyze('''
void f(List<int> x) {}
''');
    var decoratedListType = decoratedTypeAnnotation('List<int>');
    expect(decoratedFunctionType('f').positionalParameters[0],
        same(decoratedListType));
    expect(decoratedListType.node.nullable, isNotNull);
    var decoratedIntType = decoratedTypeAnnotation('int');
    expect(decoratedListType.typeArguments[0], same(decoratedIntType));
    expect(decoratedIntType.node.nullable, isNotNull);
  }

  test_topLevelFunction_parameterType_implicit_dynamic() async {
    await analyze('''
void f(x) {}
''');
    var decoratedType =
        _variables.decoratedElementType(findNode.simple('x').staticElement);
    expect(decoratedFunctionType('f').positionalParameters[0],
        same(decoratedType));
    expect(decoratedType.type.isDynamic, isTrue);
    expect(decoratedType.node.nullable, same(ConstraintVariable.always));
  }

  test_topLevelFunction_parameterType_named_no_default() async {
    await analyze('''
void f({String s}) {}
''');
    var decoratedType = decoratedTypeAnnotation('String');
    var functionType = decoratedFunctionType('f');
    expect(functionType.namedParameters['s'], same(decoratedType));
    expect(decoratedType.node.nullable, isNotNull);
    expect(decoratedType.node.nullable, isNot(same(ConstraintVariable.always)));
    expect(functionType.namedParameters['s'].node.isPossiblyOptional, true);
  }

  test_topLevelFunction_parameterType_named_no_default_required() async {
    addMetaPackage();
    await analyze('''
import 'package:meta/meta.dart';
void f({@required String s}) {}
''');
    var decoratedType = decoratedTypeAnnotation('String');
    var functionType = decoratedFunctionType('f');
    expect(functionType.namedParameters['s'], same(decoratedType));
    expect(decoratedType.node.nullable, isNotNull);
    expect(decoratedType.node.nullable, isNot(same(ConstraintVariable.always)));
    expect(functionType.namedParameters['s'].node.isPossiblyOptional, false);
  }

  test_topLevelFunction_parameterType_named_with_default() async {
    await analyze('''
void f({String s: 'x'}) {}
''');
    var decoratedType = decoratedTypeAnnotation('String');
    var functionType = decoratedFunctionType('f');
    expect(functionType.namedParameters['s'], same(decoratedType));
    expect(decoratedType.node.nullable, isNotNull);
    expect(functionType.namedParameters['s'].node.isPossiblyOptional, false);
  }

  test_topLevelFunction_parameterType_positionalOptional() async {
    await analyze('''
void f([int i]) {}
''');
    var decoratedType = decoratedTypeAnnotation('int');
    expect(decoratedFunctionType('f').positionalParameters[0],
        same(decoratedType));
    expect(decoratedType.node.nullable, isNotNull);
  }

  test_topLevelFunction_parameterType_simple() async {
    await analyze('''
void f(int i) {}
''');
    var decoratedType = decoratedTypeAnnotation('int');
    expect(decoratedFunctionType('f').positionalParameters[0],
        same(decoratedType));
    expect(decoratedType.node.nullable, isNotNull);
    expect(decoratedType.node.nonNullIntent, isNotNull);
  }

  test_topLevelFunction_returnType_implicit_dynamic() async {
    await analyze('''
f() {}
''');
    var decoratedType = decoratedFunctionType('f').returnType;
    expect(decoratedType.type.isDynamic, isTrue);
    expect(decoratedType.node.nullable, same(ConstraintVariable.always));
  }

  test_topLevelFunction_returnType_simple() async {
    await analyze('''
int f() => 0;
''');
    var decoratedType = decoratedTypeAnnotation('int');
    expect(decoratedFunctionType('f').returnType, same(decoratedType));
    expect(decoratedType.node.nullable, isNotNull);
  }
}

class MigrationVisitorTestBase extends AbstractSingleUnitTest {
  final _variables = _Variables();

  FindNode findNode;

  TypeProvider get typeProvider => testAnalysisResult.typeProvider;

  Future<CompilationUnit> analyze(String code,
      {NullabilityMigrationAssumptions assumptions:
          const NullabilityMigrationAssumptions()}) async {
    await resolveTestUnit(code);
    testUnit.accept(
        ConstraintVariableGatherer(_variables, testSource, false, assumptions));
    findNode = FindNode(code, testUnit);
    return testUnit;
  }

  /// Gets the [DecoratedType] associated with the type annotation whose text
  /// is [text].
  DecoratedType decoratedTypeAnnotation(String text) {
    return _variables.decoratedTypeAnnotation(findNode.typeAnnotation(text));
  }

  NullabilityNode possiblyOptionalParameter(String text) {
    return _variables
        .possiblyOptionalParameter(findNode.defaultParameter(text));
  }

  /// Gets the [ConditionalDiscard] information associated with the statement
  /// whose text is [text].
  ConditionalDiscard statementDiscard(String text) {
    return _variables.conditionalDiscard(findNode.statement(text));
  }
}

/// Mock representation of a constraint equation that is not connected to a
/// constraint solver.  We use this to confirm that analysis produces the
/// correct constraint equations.
///
/// [hashCode] and equality are implemented using [toString] for simplicity.
class _Clause {
  final Set<ConstraintVariable> conditions;
  final ConstraintVariable consequence;

  _Clause(this.conditions, this.consequence);

  @override
  int get hashCode => toString().hashCode;

  @override
  bool operator ==(Object other) =>
      other is _Clause && toString() == other.toString();

  @override
  String toString() {
    String lhs;
    if (conditions.isNotEmpty) {
      var sortedConditionStrings = conditions.map((v) => v.toString()).toList()
        ..sort();
      lhs = sortedConditionStrings.join(' & ') + ' => ';
    } else {
      lhs = '';
    }
    String rhs = consequence.toString();
    return lhs + rhs;
  }
}

/// Mock representation of a constraint solver that does not actually do any
/// solving.  We use this to confirm that analysis produced the correct
/// constraint equations.
class _Constraints extends Constraints {
  final _clauses = <_Clause>[];

  @override
  void record(
      Iterable<ConstraintVariable> conditions, ConstraintVariable consequence) {
    _clauses.add(_Clause(conditions.toSet(), consequence));
  }
}

/// Mock representation of constraint variables.
class _Variables extends Variables {
  final _conditionalDiscard = <AstNode, ConditionalDiscard>{};

  final _decoratedExpressionTypes = <Expression, DecoratedType>{};

  final _decoratedTypeAnnotations = <TypeAnnotation, DecoratedType>{};

  final _expressionChecks = <Expression, ExpressionChecks>{};

  final _possiblyOptional = <DefaultFormalParameter, NullabilityNode>{};

  /// Gets the [ExpressionChecks] associated with the given [expression].
  ExpressionChecks checkExpression(Expression expression) =>
      _expressionChecks[_normalizeExpression(expression)];

  /// Gets the [conditionalDiscard] associated with the given [expression].
  ConditionalDiscard conditionalDiscard(AstNode node) =>
      _conditionalDiscard[node];

  /// Gets the [DecoratedType] associated with the given [expression].
  DecoratedType decoratedExpressionType(Expression expression) =>
      _decoratedExpressionTypes[_normalizeExpression(expression)];

  /// Gets the [DecoratedType] associated with the given [typeAnnotation].
  DecoratedType decoratedTypeAnnotation(TypeAnnotation typeAnnotation) =>
      _decoratedTypeAnnotations[typeAnnotation];

  /// Gets the [NullabilityNode] associated with the possibility that
  /// [parameter] may be optional.
  NullabilityNode possiblyOptionalParameter(DefaultFormalParameter parameter) =>
      _possiblyOptional[parameter];

  @override
  void recordConditionalDiscard(
      Source source, AstNode node, ConditionalDiscard conditionalDiscard) {
    _conditionalDiscard[node] = conditionalDiscard;
    super.recordConditionalDiscard(source, node, conditionalDiscard);
  }

  void recordDecoratedExpressionType(Expression node, DecoratedType type) {
    super.recordDecoratedExpressionType(node, type);
    _decoratedExpressionTypes[_normalizeExpression(node)] = type;
  }

  void recordDecoratedTypeAnnotation(
      Source source, TypeAnnotation node, DecoratedType type) {
    super.recordDecoratedTypeAnnotation(source, node, type);
    _decoratedTypeAnnotations[node] = type;
  }

  @override
  void recordExpressionChecks(
      Source source, Expression expression, ExpressionChecks checks) {
    super.recordExpressionChecks(source, expression, checks);
    _expressionChecks[_normalizeExpression(expression)] = checks;
  }

  @override
  void recordPossiblyOptional(
      Source source, DefaultFormalParameter parameter, NullabilityNode node) {
    _possiblyOptional[parameter] = node;
    super.recordPossiblyOptional(source, parameter, node);
  }

  /// Unwraps any parentheses surrounding [expression].
  Expression _normalizeExpression(Expression expression) {
    while (expression is ParenthesizedExpression) {
      expression = (expression as ParenthesizedExpression).expression;
    }
    return expression;
  }
}
