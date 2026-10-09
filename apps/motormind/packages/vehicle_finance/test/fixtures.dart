/// Assumption literals shared by the package tests.
///
/// Every calculator takes a caller-supplied [Assumption] for the rate it was
/// handed; these stand in for the ones advisor_core builds from its tables.
library;

import 'package:vehicle_finance/vehicle_finance.dart';

/// APR assumption for loan and deal tests: a flat "6%" from a test source.
const Assumption aprAssumption = Assumption(
  key: 'apr.test',
  description: 'test',
  value: '6%',
  source: 'test',
  asOf: assumptionsReviewedOn,
);

/// Money-factor assumption for lease tests, matching the worked example's
/// 0.00125 (3% APR equivalent).
const Assumption moneyFactorAssumption = Assumption(
  key: 'lease.mf',
  description: 'test',
  value: '0.00125',
  source: 'test',
  asOf: assumptionsReviewedOn,
);

/// Trade-in value assumption: the user typed the number in.
const Assumption tradeValueAssumption = Assumption(
  key: 'trade.value',
  description: 'test',
  value: 'user',
  source: 'user',
  asOf: assumptionsReviewedOn,
);
