import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../shared/theme/app_theme.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final AuthService _authService = AuthService();

  final TextEditingController _usernameController =
  TextEditingController();

  final TextEditingController _phoneController =
  TextEditingController();

  bool _isLoading = true;
  bool _isSaving = false;
  bool _isEditing = false;

  String _email = '';
  String _provider = '';
  String _uid = '';

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    final user = _authService.currentUser;

    if (user == null) {
      if (!mounted) return;

      setState(() {
        _isLoading = false;
      });

      return;
    }

    try {
      final profile = await _authService.getUserProfile();

      if (!mounted) return;

      setState(() {
        _usernameController.text =
            profile?['username']?.toString() ??
                user.displayName ??
                '';

        _phoneController.text =
            profile?['phoneNumber']?.toString() ??
                user.phoneNumber ??
                '';

        _email = user.email ?? '';
        _uid = user.uid;

        if (_authService.isGoogleUser) {
          _provider = 'Google';
        } else if (_authService.isPasswordUser) {
          _provider = 'Email & Password';
        } else {
          _provider = 'Unknown';
        }

        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;

      setState(() {
        _usernameController.text =
            user.displayName ?? '';

        _phoneController.text =
            user.phoneNumber ?? '';

        _email = user.email ?? '';
        _uid = user.uid;

        if (_authService.isGoogleUser) {
          _provider = 'Google';
        } else if (_authService.isPasswordUser) {
          _provider = 'Email & Password';
        } else {
          _provider = 'Unknown';
        }

        _isLoading = false;
      });

      _showMessage(
        'Unable to load saved profile details.',
      );
    }
  }

  void _startEditing() {
    setState(() {
      _isEditing = true;
    });
  }

  Future<void> _saveProfile() async {
    final username = _usernameController.text.trim();
    final phone = _phoneController.text.trim();

    if (username.isEmpty) {
      _showMessage(
        'Please enter your username.',
      );
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      await _authService.updateProfile(
        username: username,
        phoneNumber: phone,
      );

      if (!mounted) return;

      setState(() {
        _isSaving = false;
        _isEditing = false;
      });

      _showMessage(
        'Profile updated successfully.',
      );
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;

      setState(() {
        _isSaving = false;
      });

      _showMessage(
        e.message ??
            'Unable to update profile.',
      );
    } catch (_) {
      if (!mounted) return;

      setState(() {
        _isSaving = false;
      });

      _showMessage(
        'Unable to update profile.',
      );
    }
  }

  Future<void> _showChangePasswordDialog() async {
    final currentPasswordController =
    TextEditingController();

    final newPasswordController =
    TextEditingController();

    final confirmPasswordController =
    TextEditingController();

    final changed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        bool loading = false;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text(
                'Change Password',
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller:
                      currentPasswordController,
                      obscureText: true,
                      decoration:
                      const InputDecoration(
                        labelText:
                        'Current Password',
                        prefixIcon: Icon(
                          Icons.lock_outline,
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller:
                      newPasswordController,
                      obscureText: true,
                      decoration:
                      const InputDecoration(
                        labelText:
                        'New Password',
                        prefixIcon: Icon(
                          Icons.lock_reset,
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller:
                      confirmPasswordController,
                      obscureText: true,
                      decoration:
                      const InputDecoration(
                        labelText:
                        'Confirm New Password',
                        prefixIcon: Icon(
                          Icons.lock_rounded,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: loading
                      ? null
                      : () {
                    Navigator.pop(
                      dialogContext,
                      false,
                    );
                  },
                  child:
                  const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: loading
                      ? null
                      : () async {
                    final currentPassword =
                        currentPasswordController
                            .text;

                    final newPassword =
                        newPasswordController
                            .text;

                    final confirmPassword =
                        confirmPasswordController
                            .text;

                    if (currentPassword.isEmpty ||
                        newPassword.isEmpty ||
                        confirmPassword.isEmpty) {
                      _showMessage(
                        'Please fill in all password fields.',
                      );
                      return;
                    }

                    if (newPassword.length < 6) {
                      _showMessage(
                        'New password must be at least 6 characters.',
                      );
                      return;
                    }

                    if (newPassword !=
                        confirmPassword) {
                      _showMessage(
                        'New passwords do not match.',
                      );
                      return;
                    }

                    setDialogState(() {
                      loading = true;
                    });

                    try {
                      await _authService.changePassword(
                        currentPassword:
                        currentPassword,
                        newPassword:
                        newPassword,
                      );

                      if (!mounted) return;

                      if (dialogContext.mounted) {
                        Navigator.pop(
                          dialogContext,
                          true,
                        );
                      }
                    } on FirebaseAuthException catch (e) {
                      if (dialogContext.mounted) {
                        setDialogState(() {
                          loading = false;
                        });
                      }

                      _showMessage(
                        _firebaseMessage(e),
                      );
                    } catch (_) {
                      if (dialogContext.mounted) {
                        setDialogState(() {
                          loading = false;
                        });
                      }

                      _showMessage(
                        'Unable to change password.',
                      );
                    }
                  },
                  child: loading
                      ? const SizedBox(
                    width: 18,
                    height: 18,
                    child:
                    CircularProgressIndicator(
                      strokeWidth: 2,
                    ),
                  )
                      : const Text(
                    'Change Password',
                  ),
                ),
              ],
            );
          },
        );
      },
    );

    currentPasswordController.dispose();
    newPasswordController.dispose();
    confirmPasswordController.dispose();

    if (changed == true) {
      _showMessage(
        'Password changed successfully.',
      );
    }
  }

  Future<void> _showDeleteAccountDialog() async {
    if (_authService.isPasswordUser) {
      await _deletePasswordAccount();
      return;
    }

    if (_authService.isGoogleUser) {
      await _deleteGoogleAccount();
      return;
    }

    _showMessage(
      'Account deletion is unavailable for this account.',
    );
  }

  Future<void> _deletePasswordAccount() async {
    final passwordController =
    TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        bool deleting = false;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title:
              const Text('Delete Account'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize:
                  MainAxisSize.min,
                  children: [
                    const Text(
                      'This action cannot be undone. '
                          'Enter your current password to continue.',
                    ),
                    const SizedBox(height: 18),
                    TextField(
                      controller:
                      passwordController,
                      obscureText: true,
                      decoration:
                      const InputDecoration(
                        labelText:
                        'Current Password',
                        prefixIcon: Icon(
                          Icons.lock_outline,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: deleting
                      ? null
                      : () {
                    Navigator.pop(
                      dialogContext,
                      false,
                    );
                  },
                  child:
                  const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: deleting
                      ? null
                      : () async {
                    final password =
                        passwordController
                            .text;

                    if (password.isEmpty) {
                      _showMessage(
                        'Please enter your password.',
                      );
                      return;
                    }

                    setDialogState(() {
                      deleting = true;
                    });

                    try {
                      await _authService
                          .deletePasswordAccount(
                        currentPassword:
                        password,
                      );

                      if (!mounted) return;

                      if (dialogContext.mounted) {
                        Navigator.pop(
                          dialogContext,
                          true,
                        );
                      }
                    } on FirebaseAuthException catch (e) {
                      if (dialogContext.mounted) {
                        setDialogState(() {
                          deleting = false;
                        });
                      }

                      _showMessage(
                        _firebaseMessage(e),
                      );
                    } catch (_) {
                      if (dialogContext.mounted) {
                        setDialogState(() {
                          deleting = false;
                        });
                      }

                      _showMessage(
                        'Unable to delete account.',
                      );
                    }
                  },
                  style:
                  ElevatedButton.styleFrom(
                    backgroundColor:
                    AppColors.critical,
                  ),
                  child: deleting
                      ? const SizedBox(
                    width: 18,
                    height: 18,
                    child:
                    CircularProgressIndicator(
                      strokeWidth: 2,
                    ),
                  )
                      : const Text(
                    'Delete Account',
                  ),
                ),
              ],
            );
          },
        );
      },
    );

    passwordController.dispose();

    if (confirmed == true && mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _deleteGoogleAccount() async {
    final confirmed =
    await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title:
          const Text('Delete Account'),
          content: const Text(
            'Your Google account will be asked to authenticate '
                'again before deletion. This action cannot be undone.',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(
                  dialogContext,
                  false,
                );
              },
              child:
              const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(
                  dialogContext,
                  true,
                );
              },
              style:
              ElevatedButton.styleFrom(
                backgroundColor:
                AppColors.critical,
              ),
              child:
              const Text('Continue'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return;

    try {
      await _authService
          .deleteGoogleAccount();

      if (!mounted) return;

      Navigator.of(context).pop();
    } on FirebaseAuthException catch (e) {
      _showMessage(
        _firebaseMessage(e),
      );
    } catch (_) {
      _showMessage(
        'Unable to delete account.',
      );
    }
  }

  Future<void> _logout() async {
    try {
      await _authService.logout();

      if (!mounted) return;

      Navigator.of(context).pop();
    } catch (_) {
      _showMessage(
        'Unable to log out. Please try again.',
      );
    }
  }

  String _firebaseMessage(
      FirebaseAuthException e,
      ) {
    switch (e.code) {
      case 'wrong-password':
      case 'invalid-credential':
        return 'Current password is incorrect.';

      case 'weak-password':
        return 'The new password is too weak.';

      case 'requires-recent-login':
        return 'Please log in again before making this change.';

      default:
        return e.message ??
            'Something went wrong.';
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
        .showSnackBar(
      SnackBar(
        content: Text(message),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor:
      AppColors.background,
      appBar: AppBar(
        title: const Text(
          'My Profile',
          style: TextStyle(
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: _isLoading
          ? const Center(
        child:
        CircularProgressIndicator(
          color: AppColors.gold,
        ),
      )
          : SafeArea(
        child: ListView(
          padding:
          const EdgeInsets.fromLTRB(
            20,
            20,
            20,
            30,
          ),
          children: [
            _buildHeader(),

            const SizedBox(height: 24),

            _buildProfileDetails(),

            const SizedBox(height: 20),

            _buildAccountSection(),

            const SizedBox(height: 20),

            _buildDeleteAccountSection(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final user =
        _authService.currentUser;

    final String? photoUrl =
        user?.photoURL;

    final firstLetter =
    _usernameController.text.isNotEmpty
        ? _usernameController.text
        .substring(0, 1)
        .toUpperCase()
        : '?';

    final hasGooglePhoto =
        photoUrl != null &&
            photoUrl.isNotEmpty;

    return Column(
      children: [
        CircleAvatar(
          radius: 50,
          backgroundColor:
          AppColors.gold,
          child: CircleAvatar(
            radius: 47,
            backgroundColor:
            AppColors.surface,
            backgroundImage:
            hasGooglePhoto
                ? NetworkImage(photoUrl)
                : null,
            child: !hasGooglePhoto
                ? Text(
              firstLetter,
              style:
              const TextStyle(
                color:
                AppColors.gold,
                fontSize: 34,
                fontWeight:
                FontWeight.w900,
              ),
            )
                : null,
          ),
        ),

        const SizedBox(height: 14),

        Text(
          _usernameController.text.isEmpty
              ? 'HomeBound User'
              : _usernameController.text,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 22,
            fontWeight:
            FontWeight.w800,
          ),
        ),

        const SizedBox(height: 5),

        Text(
          _email,
          style: const TextStyle(
            color:
            AppColors.textSecondary,
          ),
        ),
      ],
    );
  }

  Widget _buildProfileDetails() {
    return Container(
      padding:
      const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius:
        BorderRadius.circular(18),
        border: Border.all(
          color: AppColors.divider,
        ),
      ),
      child: Column(
        crossAxisAlignment:
        CrossAxisAlignment.start,
        children: [
          const Text(
            'Profile Details',
            style: TextStyle(
              fontSize: 17,
              fontWeight:
              FontWeight.w800,
            ),
          ),

          const SizedBox(height: 18),

          TextField(
            controller:
            _usernameController,
            readOnly: !_isEditing,
            decoration:
            const InputDecoration(
              labelText: 'Username',
              prefixIcon: Icon(
                Icons.person_outline,
              ),
            ),
          ),

          const SizedBox(height: 14),

          TextField(
            controller:
            _phoneController,
            readOnly: !_isEditing,
            keyboardType:
            TextInputType.phone,
            decoration:
            const InputDecoration(
              labelText:
              'Phone Number',
              prefixIcon: Icon(
                Icons.phone_outlined,
              ),
              hintText: '0123456789',
            ),
          ),

          const SizedBox(height: 14),

          TextFormField(
            initialValue: _email,
            readOnly: true,
            decoration:
            const InputDecoration(
              labelText: 'Email',
              prefixIcon: Icon(
                Icons.email_outlined,
              ),
            ),
          ),

          const SizedBox(height: 18),

          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _isSaving
                  ? null
                  : (_isEditing
                  ? _saveProfile
                  : _startEditing),
              icon: _isSaving
                  ? const SizedBox(
                width: 18,
                height: 18,
                child:
                CircularProgressIndicator(
                  strokeWidth: 2,
                ),
              )
                  : Icon(
                _isEditing
                    ? Icons.save_outlined
                    : Icons.edit_outlined,
              ),
              label: Text(
                _isSaving
                    ? 'Saving...'
                    : (_isEditing
                    ? 'Save Profile'
                    : 'Edit Profile'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAccountSection() {
    return Container(
      padding:
      const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius:
        BorderRadius.circular(18),
        border: Border.all(
          color: AppColors.divider,
        ),
      ),
      child: Column(
        crossAxisAlignment:
        CrossAxisAlignment.start,
        children: [
          const Text(
            'Account',
            style: TextStyle(
              fontSize: 17,
              fontWeight:
              FontWeight.w800,
            ),
          ),

          const SizedBox(height: 16),

          _infoRow(
            Icons.verified_user_outlined,
            'Sign-in Method',
            _provider,
          ),

          const SizedBox(height: 14),

          _infoRow(
            Icons.fingerprint,
            'User ID',
            _uid,
          ),

          if (_authService
              .isPasswordUser) ...[
            const SizedBox(height: 18),

            SizedBox(
              width: double.infinity,
              child:
              OutlinedButton.icon(
                onPressed:
                _showChangePasswordDialog,
                icon: const Icon(
                  Icons.lock_reset,
                  color: AppColors.gold,
                ),
                label: const Text(
                  'Change Password',
                ),
              ),
            ),
          ],

          const SizedBox(height: 12),

          SizedBox(
            width: double.infinity,
            child:
            OutlinedButton.icon(
              onPressed: _logout,
              icon: const Icon(
                Icons.logout_rounded,
                color: AppColors.gold,
              ),
              label:
              const Text('Log Out'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeleteAccountSection() {
    return Column(
      crossAxisAlignment:
      CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed:
            _showDeleteAccountDialog,
            style:
            ElevatedButton.styleFrom(
              backgroundColor:
              AppColors.critical,
              padding:
              const EdgeInsets.symmetric(
                vertical: 16,
              ),
            ),
            icon: const Icon(
              Icons.delete_forever_rounded,
            ),
            label: const Text(
              'Delete Account',
              style: TextStyle(
                fontWeight:
                FontWeight.w700,
              ),
            ),
          ),
        ),

        const SizedBox(height: 10),

        const Text(
          'Deleting your account permanently removes your '
              'HomeBound profile and cannot be undone.',
          style: TextStyle(
            color:
            AppColors.textSecondary,
            fontSize: 12,
            height: 1.5,
          ),
        ),
      ],
    );
  }

  Widget _infoRow(
      IconData icon,
      String title,
      String value,
      ) {
    return Row(
      crossAxisAlignment:
      CrossAxisAlignment.start,
      children: [
        Icon(
          icon,
          color: AppColors.gold,
          size: 21,
        ),

        const SizedBox(width: 12),

        Expanded(
          child: Column(
            crossAxisAlignment:
            CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color:
                  AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),

              const SizedBox(height: 3),

              Text(
                value.isEmpty
                    ? '-'
                    : value,
                style: const TextStyle(
                  fontWeight:
                  FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}