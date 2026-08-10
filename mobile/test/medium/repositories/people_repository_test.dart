import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/entities/person.entity.drift.dart';
import 'package:immich_mobile/infrastructure/repositories/people.repository.dart';

import '../repository_context.dart';

void main() {
  late MediumRepositoryContext ctx;
  late DriftPeopleRepository sut;

  setUp(() {
    ctx = MediumRepositoryContext();
    sut = DriftPeopleRepository(ctx.db);
  });

  tearDown(() => ctx.dispose());

  test('cached person reads and updates cannot cross identities', () async {
    final userA = await ctx.newUser();
    final userB = await ctx.newUser();
    await ctx.db
        .into(ctx.db.personEntity)
        .insert(
          PersonEntityCompanion.insert(
            id: 'person-a',
            ownerId: userA.id,
            name: 'Person A',
            isFavorite: false,
            isHidden: false,
          ),
        );

    expect(await sut.get('person-a', userA.id), isNotNull);
    expect(await sut.get('person-a', userB.id), isNull);
    expect(await sut.updateName('person-a', userB.id, 'Leaked'), 0);
    expect((await sut.get('person-a', userA.id))?.name, 'Person A');
    expect(await sut.updateName('person-a', userA.id, 'Updated'), 1);
    expect((await sut.get('person-a', userA.id))?.name, 'Updated');
  });
}
