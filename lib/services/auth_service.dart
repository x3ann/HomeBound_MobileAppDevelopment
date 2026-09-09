import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final GoogleSignIn _googleSignIn = GoogleSignIn.instance;

  bool _googleInitialized = false;

  Future<void> _initializeGoogleSignIn() async {
    if (_googleInitialized) return;

    await _googleSignIn.initialize();
    _googleInitialized = true;
  }

  // Email + Password Login
  Future<User?> login({
    required String email,
    required String password,
  }) async {
    final UserCredential result =
    await _auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );

    return result.user;
  }

  // Register Account
  Future<User?> register({
    required String email,
    required String password,
  }) async {
    final UserCredential result =
    await _auth.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );

    final user = result.user;

    if (user != null) {
      await _createUserProfileIfNeeded(user);
    }

    return user;
  }

  // Google Sign In
  Future<User?> signInWithGoogle() async {
    await _initializeGoogleSignIn();

    final GoogleSignInAccount googleUser =
    await _googleSignIn.authenticate();

    final GoogleSignInAuthentication googleAuth =
        googleUser.authentication;

    final OAuthCredential credential =
    GoogleAuthProvider.credential(
      idToken: googleAuth.idToken,
    );

    final UserCredential result =
    await _auth.signInWithCredential(credential);

    final user = result.user;

    if (user != null) {
      await _createUserProfileIfNeeded(user);
    }

    return user;
  }

  // Create Firestore profile
  Future<void> _createUserProfileIfNeeded(User user) async {
    final userRef =
    _firestore.collection('users').doc(user.uid);

    final snapshot = await userRef.get();

    if (!snapshot.exists) {
      await userRef.set({
        'uid': user.uid,
        'username': user.displayName ?? '',
        'phoneNumber': user.phoneNumber ?? '',
        'email': user.email ?? '',
        'createdAt': FieldValue.serverTimestamp(),
      });
    }
  }

  // Get profile details
  Future<Map<String, dynamic>?> getUserProfile() async {
    final user = _auth.currentUser;

    if (user == null) return null;

    final snapshot =
    await _firestore.collection('users').doc(user.uid).get();

    if (!snapshot.exists) {
      await _createUserProfileIfNeeded(user);

      final newSnapshot =
      await _firestore.collection('users').doc(user.uid).get();

      return newSnapshot.data();
    }

    return snapshot.data();
  }

  // Update username and phone number
  Future<void> updateProfile({
    required String username,
    required String phoneNumber,
  }) async {
    final user = _auth.currentUser;

    if (user == null) {
      throw FirebaseAuthException(
        code: 'no-user',
        message: 'No user is currently signed in.',
      );
    }

    await _firestore.collection('users').doc(user.uid).set({
      'uid': user.uid,
      'username': username.trim(),
      'phoneNumber': phoneNumber.trim(),
      'email': user.email ?? '',
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    await user.updateDisplayName(username.trim());
  }

  // Reset Password
  Future<void> resetPassword(String email) async {
    await _auth.sendPasswordResetEmail(
      email: email.trim(),
    );
  }

  // Change password
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final user = _auth.currentUser;

    if (user == null) {
      throw FirebaseAuthException(
        code: 'no-user',
        message: 'No user is currently signed in.',
      );
    }

    final email = user.email;

    if (email == null) {
      throw FirebaseAuthException(
        code: 'no-email',
        message: 'This account does not have an email address.',
      );
    }

    final credential = EmailAuthProvider.credential(
      email: email,
      password: currentPassword,
    );

    await user.reauthenticateWithCredential(credential);

    await user.updatePassword(newPassword);
  }

  // Delete Email/Password account
  Future<void> deletePasswordAccount({
    required String currentPassword,
  }) async {
    final user = _auth.currentUser;

    if (user == null) {
      throw FirebaseAuthException(
        code: 'no-user',
        message: 'No user is currently signed in.',
      );
    }

    final email = user.email;

    if (email == null) {
      throw FirebaseAuthException(
        code: 'no-email',
        message: 'This account does not have an email address.',
      );
    }

    final credential = EmailAuthProvider.credential(
      email: email,
      password: currentPassword,
    );

    await user.reauthenticateWithCredential(credential);

    await _firestore
        .collection('users')
        .doc(user.uid)
        .delete();

    await user.delete();
  }

  // Delete Google account
  Future<void> deleteGoogleAccount() async {
    final user = _auth.currentUser;

    if (user == null) {
      throw FirebaseAuthException(
        code: 'no-user',
        message: 'No user is currently signed in.',
      );
    }

    await _initializeGoogleSignIn();

    final GoogleSignInAccount googleUser =
    await _googleSignIn.authenticate();

    final GoogleSignInAuthentication googleAuth =
        googleUser.authentication;

    final credential = GoogleAuthProvider.credential(
      idToken: googleAuth.idToken,
    );

    await user.reauthenticateWithCredential(credential);

    await _firestore
        .collection('users')
        .doc(user.uid)
        .delete();

    await user.delete();

    try {
      await _googleSignIn.signOut();
    } catch (_) {}
  }

  // Logout
  Future<void> logout() async {
    await _auth.signOut();

    try {
      await _initializeGoogleSignIn();
      await _googleSignIn.signOut();
    } catch (_) {}
  }

  // Current logged in user
  User? get currentUser => _auth.currentUser;

  // Email/password provider
  bool get isPasswordUser {
    final user = _auth.currentUser;

    if (user == null) return false;

    return user.providerData.any(
          (provider) => provider.providerId == 'password',
    );
  }

  // Google provider
  bool get isGoogleUser {
    final user = _auth.currentUser;

    if (user == null) return false;

    return user.providerData.any(
          (provider) => provider.providerId == 'google.com',
    );
  }
}