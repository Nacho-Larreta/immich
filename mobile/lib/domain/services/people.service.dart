import 'dart:async';

import 'package:immich_mobile/domain/models/person.model.dart';
import 'package:immich_mobile/infrastructure/repositories/people.repository.dart';
import 'package:immich_mobile/repositories/person_api.repository.dart';

class DriftPeopleService {
  final DriftPeopleRepository _repository;
  final PersonApiRepository _personApiRepository;

  const DriftPeopleService(this._repository, this._personApiRepository);

  Future<DriftPerson?> get(String personId, String ownerId) {
    return _repository.get(personId, ownerId);
  }

  Future<List<DriftPerson>> getAssetPeople(String assetId, String ownerId) {
    return _repository.getAssetPeople(assetId, ownerId);
  }

  Future<List<DriftPerson>> getAllPeople(String ownerId) {
    return _repository.getAllPeople(ownerId);
  }

  Future<int> updateName(String personId, String ownerId, String name) async {
    await _personApiRepository.update(personId, name: name);
    return _repository.updateName(personId, ownerId, name);
  }

  Future<int> updateBrithday(String personId, String ownerId, DateTime birthday) async {
    await _personApiRepository.update(personId, birthday: birthday);
    return _repository.updateBirthday(personId, ownerId, birthday);
  }
}
